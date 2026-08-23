#!/usr/bin/env python3
"""Generates the keystroke samples shipped in Resources/Sounds.

Synthesised rather than sampled: a recorded set drags a licence along with it,
and every recording still needs per-keystroke variation to stop it sounding like
a loop.

Two earlier attempts got this wrong in instructive ways. The first gave every
set a big low sine, which is a kick drum. The second replaced it with sine
"resonances", which is a marimba — a pure tone reads as a musical note no matter
how short you make it, and a keyboard has no notes in it.

What an impact actually is: a very short burst of broadband noise, shaped by the
resonances of whatever was struck. So that is what this models — a noise
excitation through parallel resonant band-pass filters. Q sets how long each
resonance rings, which is the difference between plastic (low Q, dead) and metal
(high Q, singing). Only the cosmic set uses oscillators, because a film console
is supposed to sound synthetic.

Deterministic: fixed seeds mean regenerating produces byte-identical files.
"""
import math, os, random, struct, wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds")
SETS = ("click", "typewriter", "soft", "cosmic")


def bandpass(x, f0, q):
    """One resonant band. Constant-skirt biquad; peak gain is Q."""
    w0 = 2 * math.pi * f0 / RATE
    alpha = math.sin(w0) / (2 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    out = []
    x1 = x2 = y1 = y2 = 0.0
    for s in x:
        y = b0 * s + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, s
        y2, y1 = y1, y
        out.append(y)
    return out


def noise(rng, n, tau, colour=0.5, burst_ms=None):
    """Noise under an exponential envelope.

    The envelope carries the duration and the filters only colour it. Relying on
    filter ring instead was the mistake in the previous version: ring time is
    roughly Q/(pi*f), so a 2.4 kHz band needs a Q in the hundreds to last even
    30 ms — and by then it is a sine tone again. Real impacts are broadband for
    their whole length; the decay comes from many modes at once, not one sharp
    one.
    """
    out, lp = [], 0.0
    hold = int(RATE * burst_ms / 1000) if burst_ms else n
    for i in range(n):
        t = i / RATE
        lp += colour * ((rng.uniform(-1, 1) if i < hold else 0.0) - lp)
        # 0.3 ms fade-in so the very first sample is not a step.
        out.append(lp * math.exp(-t / tau) * min(1.0, t / 0.0003))
    return out


def mix(parts, n):
    out = [0.0] * n
    for samples, gain in parts:
        for i in range(min(n, len(samples))):
            out[i] += samples[i] * gain
    return out


def render_click(rng, pitch, length=0.075):
    """A plastic keycap on a plate: bright, dry, over in about 40 ms."""
    n = int(RATE * length)
    strike = noise(rng, n, 0.0045, colour=0.75)
    body = noise(rng, n, 0.0090, colour=0.45)
    return mix([
        (bandpass(strike, 2600 * pitch, 3.0), 1.00),   # the click
        (bandpass(strike, 4400 * pitch, 2.5), 0.45),   # top edge
        (bandpass(body, 950 * pitch, 2.5), 0.75),      # keycap
        (bandpass(body, 420 * pitch, 2.0), 0.40),      # plate, kept quiet
    ], n)


def render_typewriter(rng, pitch, length=0.24):
    """A type bar on a platen: a hard strike, then metal ringing after it."""
    n = int(RATE * length)
    strike = noise(rng, n, 0.0035, colour=0.85, burst_ms=3)
    ring = noise(rng, n, 0.055, colour=0.9)
    knock = noise(rng, n, 0.014, colour=0.35)
    return mix([
        (bandpass(strike, 3200 * pitch, 2.5), 0.95),   # the impact
        (bandpass(ring, 3400 * pitch, 22), 0.55),      # narrow: this is the metal
        (bandpass(ring, 5100 * pitch, 18), 0.30),
        (bandpass(ring, 2050 * pitch, 16), 0.35),
        (bandpass(knock, 640 * pitch, 3.0), 0.70),     # the wooden knock under it
        (bandpass(knock, 310 * pitch, 2.5), 0.40),
    ], n)


def render_soft(rng, pitch, length=0.06):
    """A rubber dome: almost all body, no ring, quiet."""
    n = int(RATE * length)
    body = noise(rng, n, 0.0075, colour=0.22)
    return mix([
        (bandpass(body, 700 * pitch, 2.0), 1.00),
        (bandpass(body, 1450 * pitch, 2.0), 0.35),
        (bandpass(body, 330 * pitch, 2.0), 0.50),
    ], n)


def render_cosmic(rng, pitch, length=0.13, base=720):
    """A ship's console in a film made before anyone had used a computer.

    Oscillators on purpose: this one is meant to sound synthetic. A short blip
    that slides upward, with a little noise on the attack to give it an edge.
    """
    n = int(RATE * length)
    f0 = base * pitch
    edge = noise(rng, n, 0.0025, colour=0.9, burst_ms=2)
    out, phase = [], 0.0
    for i in range(n):
        t = i / RATE
        f = f0 * (1.0 + 0.26 * (t / length))
        phase += 2 * math.pi * f / RATE
        env = min(1.0, t / 0.002) * math.exp(-t / 0.030)
        out.append((math.sin(phase) + 0.22 * math.sin(3 * phase)) * env * 0.9
                   + edge[i] * 0.30)
    return out


RENDERERS = {"click": render_click, "typewriter": render_typewriter,
             "soft": render_soft, "cosmic": render_cosmic}

# Cosmic steps through a scale so a burst of typing sounds like a console
# working rather than like a fault. The others detune by a few percent only.
COSMIC_STEPS = [1.0, 1.122, 1.26, 1.335, 1.498, 1.682, 0.891, 0.943]


def normalise(samples, peak_target=0.85):
    peak = max(1e-9, max(abs(v) for v in samples))
    return [v / peak * peak_target for v in samples]


def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", max(-32767, min(32767, int(v * 32767)))) for v in samples))


def main():
    os.makedirs(OUT, exist_ok=True)
    written = 0
    for name in SETS:
        render = RENDERERS[name]
        for variant in range(8):
            rng = random.Random(f"{name}-{variant}-v3")
            pitch = COSMIC_STEPS[variant] if name == "cosmic" else 1.0 + (variant - 3.5) * 0.035
            write(os.path.join(OUT, f"{name}-{variant}.wav"), normalise(render(rng, pitch)))
            written += 1

        rng = random.Random(f"{name}-return-v3")
        if name == "cosmic":
            samples = render_cosmic(rng, 0.62, length=0.26, base=520)
        else:
            samples = render(rng, 0.80)
        write(os.path.join(OUT, f"{name}-return.wav"), normalise(samples, 0.92))
        written += 1
    print(f"wrote {written} samples to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
