import Foundation

/// A model you can install, with enough context to choose sensibly.
struct ModelCatalogEntry: Identifiable {
    var id: String { name }
    var name: String
    var approximateBytes: Int64
    var blurb: String
}

/// Talks to a local Ollama server: what is installed, what is downloading, and
/// whether the server is even running.
@MainActor
final class OllamaManager: ObservableObject {
    struct Download {
        var status: String
        var completed: Int64
        var total: Int64
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    @Published private(set) var installed: [OllamaTags.Model] = []
    @Published private(set) var isRunning = false
    @Published private(set) var downloads: [String: Download] = [:]
    @Published private(set) var lastError: String?
    /// Called when the server transitions to running, so the rest of the app
    /// can drop a stale "not running" state.
    var onBecameAvailable: (() -> Void)?

    private var tasks: [String: Task<Void, Never>] = [:]
    private let host = "http://localhost:11434"

    /// Small models chosen for this app's jobs. Everything here is labelling —
    /// classification and one-line summaries — so a 1-3B model is the right
    /// size. Bigger models cost memory without doing these tasks better.
    static let catalog: [ModelCatalogEntry] = [
        .init(name: "llama3.2:1b", approximateBytes: 1_300_000_000,
              blurb: "Fastest. Fine for tab activity and naming."),
        .init(name: "llama3.2:3b", approximateBytes: 2_000_000_000,
              blurb: "Best balance for these tasks. Recommended."),
        .init(name: "qwen2.5:3b", approximateBytes: 1_900_000_000,
              blurb: "Similar size, often crisper at short answers."),
        .init(name: "gemma3:4b", approximateBytes: 3_300_000_000,
              blurb: "Better error explanations, noticeably heavier."),
        .init(name: "qwen2.5:7b", approximateBytes: 4_700_000_000,
              blurb: "Overkill here unless you also use it elsewhere."),
    ]

    func refresh() async {
        guard let url = URL(string: "\(host)/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let tags = try JSONDecoder().decode(OllamaTags.self, from: data)
            let wasRunning = isRunning
            installed = tags.models
            isRunning = true
            lastError = nil
            if !wasRunning { onBecameAvailable?() }
        } catch {
            installed = []
            isRunning = false
        }
    }

    func isInstalled(_ name: String) -> Bool {
        installed.contains { $0.name == name || $0.model == name }
    }

    func size(of name: String) -> Int64? {
        installed.first { $0.name == name || $0.model == name }?.size
    }

    /// Starts the local server if it is installed but not running.
    func startServer() {
        let candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            lastError = "Ollama is not installed. brew install ollama"
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["serve"]
        // Detached: the server outlives this app, which is what people expect
        // from a background daemon they installed themselves.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            lastError = "Could not start Ollama"
            return
        }
        Task {
            // Give it a moment to bind before reporting failure.
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    /// Downloads a model, reporting progress as it streams.
    func pull(_ name: String) {
        guard tasks[name] == nil else { return }
        downloads[name] = Download(status: "starting", completed: 0, total: 0)

        tasks[name] = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.tasks[name] = nil
                }
            }
            guard let url = URL(string: "\(self?.host ?? "")/api/pull") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["model": name, "stream": true])
            // A model download is long; no timeout would be wrong, but the
            // default 60s is far too short.
            request.timeoutInterval = 3600

            do {
                let (stream, _) = try await URLSession.shared.bytes(for: request)
                // The response is newline-delimited JSON, one object per update.
                for try await line in stream.lines {
                    if Task.isCancelled { break }
                    guard let data = line.data(using: .utf8),
                          let update = try? JSONDecoder().decode(PullUpdate.self, from: data)
                    else { continue }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if let error = update.error {
                            self.lastError = error
                            self.downloads[name] = nil
                            return
                        }
                        self.downloads[name] = Download(
                            status: update.status,
                            completed: update.completed ?? 0,
                            total: update.total ?? 0)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Download failed"
                }
            }

            await MainActor.run { [weak self] in
                self?.downloads[name] = nil
            }
            await self?.refresh()
        }
    }

    func cancel(_ name: String) {
        tasks[name]?.cancel()
        tasks[name] = nil
        downloads[name] = nil
    }

    /// Cancels everything; called when the settings panel goes away so a
    /// half-finished download does not linger with nothing watching it.
    func cancelAll() {
        for name in tasks.keys { cancel(name) }
    }

    private struct PullUpdate: Decodable {
        var status: String
        var completed: Int64?
        var total: Int64?
        var error: String?
    }
}

extension Int64 {
    var humanBytes: String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(self)
        var unit = 0
        while size >= 1024, unit < units.count - 1 { size /= 1024; unit += 1 }
        return String(format: size < 10 && unit > 1 ? "%.1f %@" : "%.0f %@", size, units[unit])
    }
}
