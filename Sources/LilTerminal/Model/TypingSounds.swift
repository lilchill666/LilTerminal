import AVFoundation
import AppKit

/// The sample set used for keystrokes.
enum TypingSoundSet: String, Codable, CaseIterable, Identifiable {
    case click, typewriter, soft, cosmic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .click:      return "Mechanical"
        case .typewriter: return "Typewriter"
        case .soft:       return "Soft"
        case .cosmic:     return "Cosmic"
        }
    }

    var detail: String {
        switch self {
        case .click:      return "A plastic keycap: short, bright, dry."
        case .typewriter: return "A type bar hitting the platen, with the metal ring after it."
        case .soft:       return "A rubber-dome key heard through a desk."
        case .cosmic:     return "A ship's console from a film made before anyone had used a computer."
        }
    }
}

/// Plays a keystroke sound, cheaply and without repeating itself.
///
/// AVAudioEngine with preloaded buffers rather than an AVAudioPlayer per press:
/// a player allocates and decodes on every keystroke, which is exactly the wrong
/// shape for something that fires as fast as someone can type. Buffers are read
/// once; a press only schedules one.
///
/// Nothing is allocated or started until the feature is switched on, and
/// switching it off tears the engine down again — an idle audio engine keeps the
/// audio hardware awake for no reason.
@MainActor
final class TypingSounds {
    static let shared = TypingSounds()

    private var engine: AVAudioEngine?
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [AVAudioPCMBuffer] = []
    private var returnBuffer: AVAudioPCMBuffer?
    private var loadedSet: TypingSoundSet?
    private var lastVariant = -1

    /// Enough voices that a fast burst overlaps rather than cutting itself off,
    /// few enough that they cost nothing to keep around.
    private let voiceCount = 6

    private init() {}

    var isRunning: Bool { engine != nil }

    /// Brings the engine up for `set`, or tears it down when `enabled` is false.
    /// Safe to call repeatedly with the same arguments — it does nothing then.
    func configure(enabled: Bool, set: TypingSoundSet) {
        guard enabled else { return teardown() }
        guard engine == nil || loadedSet != set else { return }
        teardown()

        guard let samples = loadSamples(for: set), !samples.buffers.isEmpty else { return }
        buffers = samples.buffers
        returnBuffer = samples.returnBuffer
        loadedSet = set

        let engine = AVAudioEngine()
        let format = buffers[0].format
        for _ in 0..<voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            players.append(node)
        }
        do {
            try engine.start()
            players.forEach { $0.play() }
            self.engine = engine
        } catch {
            // No audio device, or the engine refused to start. Silence is the
            // right outcome; typing must not be affected either way.
            players.removeAll()
            buffers.removeAll()
            loadedSet = nil
        }
    }

    func teardown() {
        players.forEach { $0.stop() }
        engine?.stop()
        players.removeAll()
        buffers.removeAll()
        returnBuffer = nil
        loadedSet = nil
        engine = nil
    }

    /// - Parameter volume: 0...1, straight from preferences.
    func play(isReturn: Bool, volume: Double) {
        guard engine != nil, !players.isEmpty, !buffers.isEmpty else { return }

        let buffer: AVAudioPCMBuffer
        if isReturn, let returnBuffer {
            buffer = returnBuffer
        } else {
            // Never the same sample twice running: a repeat is the single most
            // obvious tell that a sound is canned.
            var index = Int.random(in: 0..<buffers.count)
            if buffers.count > 1 && index == lastVariant {
                index = (index + 1) % buffers.count
            }
            lastVariant = index
            buffer = buffers[index]
        }

        let node = players[next]
        next = (next + 1) % players.count
        // A little level jitter on top of the sample variation. Real keystrokes
        // are not struck with identical force.
        node.volume = Float(max(0, min(1, volume)) * Double.random(in: 0.86...1.0))
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    private func loadSamples(for set: TypingSoundSet)
        -> (buffers: [AVAudioPCMBuffer], returnBuffer: AVAudioPCMBuffer?)? {
        guard let directory = Self.soundsDirectory else { return nil }
        var loaded: [AVAudioPCMBuffer] = []
        for variant in 0..<8 {
            let url = directory.appendingPathComponent("\(set.rawValue)-\(variant).wav")
            if let buffer = Self.buffer(at: url) { loaded.append(buffer) }
        }
        let returnURL = directory.appendingPathComponent("\(set.rawValue)-return.wav")
        return (loaded, Self.buffer(at: returnURL))
    }

    private static func buffer(at url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        return buffer
    }

    /// In the packaged app the samples sit in Contents/Resources/Sounds. A plain
    /// `swift build` binary has no bundle, so the source tree is the fallback —
    /// otherwise the feature is silently missing whenever it is run that way.
    private static var soundsDirectory: URL? {
        if let resources = Bundle.main.resourceURL {
            let packaged = resources.appendingPathComponent("Sounds", isDirectory: true)
            if FileManager.default.fileExists(atPath: packaged.path) { return packaged }
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Model
            .deletingLastPathComponent()   // LilTerminal
            .deletingLastPathComponent()   // Sources
            .appendingPathComponent("Resources/Sounds", isDirectory: true)
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }
}
