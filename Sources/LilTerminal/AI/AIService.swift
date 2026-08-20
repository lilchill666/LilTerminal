import Foundation

/// Runs AI tasks, and mostly decides not to.
///
/// The scheduler is the whole point of this type. A per-tab classifier that
/// fired on every output batch across twenty tabs would be thousands of calls a
/// minute for answers that rarely change. Every request therefore has to clear
/// four gates: the feature is on, the input actually changed, the cooldown has
/// elapsed, and nothing identical is already running.
actor AIService {
    private var backend: AIBackend?
    private(set) var backendDescription = "off"
    private(set) var lastError: String?

    /// One in-flight task per key. A second request for the same key replaces
    /// the first rather than queueing behind it — the newer input is the one
    /// worth answering.
    private var inFlight: [String: Task<String, Error>] = [:]
    private var lastRunAt: [String: Date] = [:]
    private var lastInputHash: [String: Int] = [:]

    /// Serialises work. These models are small but not free; running several at
    /// once on battery is worse than being a second late.
    private var gate = 0
    private let maxConcurrent = 1

    /// Bookkeeping is pruned so a long session cannot accumulate state for tabs
    /// that no longer exist.
    private let bookkeepingLimit = 200

    func configure(_ backend: AIBackend?, description: String) {
        self.backend = backend
        self.backendDescription = description
        self.lastError = nil
        // A backend change invalidates every cached decision.
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        lastInputHash.removeAll()
        lastRunAt.removeAll()
    }

    func checkAvailability() async -> String? {
        guard let backend else { return "no backend" }
        switch await backend.availability() {
        case .success:
            lastError = nil
            return nil
        case .failure(let error):
            let message: String
            switch error {
            case .unavailable(let reason), .failed(let reason): message = reason
            }
            lastError = message
            return message
        }
    }

    /// - Parameters:
    ///   - key: identifies the question being asked, e.g. "state:<tabID>".
    ///   - inputHash: a hash of everything the answer depends on. Identical
    ///     input means the previous answer still stands, so no call is made.
    ///   - cooldown: minimum time between calls for this key.
    func run(key: String,
             inputHash: Int,
             cooldown: TimeInterval,
             request: AIRequest) async -> String? {
        guard let backend else { return nil }

        // Gate 1: the input has not changed since the last answer.
        if lastInputHash[key] == inputHash { return nil }

        // Gate 2: too soon since the last call for this key.
        if let last = lastRunAt[key], Date().timeIntervalSince(last) < cooldown { return nil }

        // Gate 3: something is already answering this exact question.
        if let existing = inFlight[key] {
            if lastInputHash[key] == inputHash { return nil }
            existing.cancel()
        }

        // Gate 4: concurrency.
        guard gate < maxConcurrent else { return nil }

        gate += 1
        lastRunAt[key] = Date()
        let task = Task<String, Error> { try await backend.complete(request) }
        inFlight[key] = task

        defer {
            gate -= 1
            inFlight[key] = nil
            pruneIfNeeded()
        }

        do {
            let value = try await task.value
            lastInputHash[key] = inputHash
            lastError = nil
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            return nil
        } catch {
            // Record the input anyway: retrying a failing model on unchanged
            // input every cooldown is exactly the pointless traffic to avoid.
            lastInputHash[key] = inputHash
            lastError = (error as? AIError).map {
                switch $0 { case .unavailable(let m), .failed(let m): return m }
            } ?? error.localizedDescription
            return nil
        }
    }

    /// A one-shot request that bypasses the change/cooldown gates, for things
    /// the user explicitly asked for.
    func runOnce(request: AIRequest) async -> String? {
        guard let backend else { return nil }
        do {
            return try await backend.complete(request)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    func forget(keyPrefix: String) {
        for key in inFlight.keys where key.hasPrefix(keyPrefix) {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
        lastRunAt = lastRunAt.filter { !$0.key.hasPrefix(keyPrefix) }
        lastInputHash = lastInputHash.filter { !$0.key.hasPrefix(keyPrefix) }
    }

    func cancelAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private func pruneIfNeeded() {
        guard lastRunAt.count > bookkeepingLimit else { return }
        // Drop the oldest half; these are only optimisation hints, so losing
        // them costs at most one redundant call each.
        let sorted = lastRunAt.sorted { $0.value < $1.value }
        for (key, _) in sorted.prefix(lastRunAt.count / 2) {
            lastRunAt[key] = nil
            lastInputHash[key] = nil
        }
    }
}
