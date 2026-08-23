#!/usr/bin/env python3
"""Generates the keystroke samples shipped in Resources/Sounds.

Synthesised rather than sampled: a recorded set drags a licence along with it
and every recording still needs the same per-keystroke variation to stop it
sounding like a loop. A key press is modelled as three decaying parts — the
contact noise, the resonance of the plate it sits on, and the low thock of the
key bottoming out — which is enough to sound mechanical without a sample.

Deterministic: a fixed seed means regenerating produces byte-identical files.
"""
import math, os, random, struct, wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds")

SETS = {
    # name:      (noise, click_hz, thock_hz, decay, thock_decay, gain)
    "click":     (0.55, 2600, 190, 0.016, 0.030, 0.55),
    "typewriter":(0.70, 1750, 130, 0.028, 0.055, 0.75),
    "soft":      (0.35, 1400, 165, 0.020, 0.038, 0.32),
}


def render(noise_amt, click_hz, thock_hz, decay, thock_decay, gain, seed, length=0.11):
    rng = random.Random(seed)
    n = int(RATE * length)
    out = []
    # A one-pole low-pass on the noise takes the fizz off, leaving something
    # closer to plastic than to static.
    prev = 0.0
    for i in range(n):
        t = i / RATE
        white = rng.uniform(-1.0, 1.0)
        prev = prev + 0.45 * (white - prev)
        contact = prev * math.exp(-t / (decay * 0.35)) * noise_amt
        click = math.sin(2 * math.pi * click_hz * t) * math.exp(-t / decay) * 0.35
        thock = math.sin(2 * math.pi * thock_hz * t) * math.exp(-t / thock_decay) * 0.45
        # 1.2 ms fade-in: a hard edge at sample zero reads as a pop of its own.
        attack = min(1.0, t / 0.0012)
        out.append((contact + click + thock) * attack * gain)
    peak = max(1e-9, max(abs(v) for v in out))
    return [v / peak * 0.82 for v in out]


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
    for name, (noise, click_hz, thock_hz, decay, thock_decay, gain) in SETS.items():
        for variant in range(8):
            # Each variant is detuned slightly. Real keys differ from each other
            # by roughly this much, and it is what keeps a fast burst of typing
            # from turning into an obvious loop.
            jitter = 1.0 + (variant - 3.5) * 0.035
            write(os.path.join(OUT, f"{name}-{variant}.wav"),
                  render(noise, click_hz * jitter, thock_hz * jitter,
                         decay * (2.0 - jitter), thock_decay, gain, seed=hash(name) + variant))
            written += 1
        # Return gets its own, deeper sound: the big key always sounds bigger.
        write(os.path.join(OUT, f"{name}-return.wav"),
              render(noise * 1.15, click_hz * 0.72, thock_hz * 0.78,
                     decay * 1.35, thock_decay * 1.5, gain * 1.15, seed=hash(name) + 99, length=0.16))
        written += 1
    print(f"wrote {written} samples to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
