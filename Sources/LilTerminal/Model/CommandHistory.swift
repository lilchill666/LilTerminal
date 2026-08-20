import Foundation

/// One command run in a session.
struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var command: String
    var directory: String?
    var startedAt: Date
    var finishedAt: Date?
    /// Only known when the shell reports it via OSC 133; nil otherwise.
    var exitCode: Int32?
    /// One-line explanation of a failure, when AI triage is on.
    var triage: String?

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var isRunning: Bool { finishedAt == nil }

    /// Commands worth notifying about, and worth showing a duration for.
    var wasLongRunning: Bool { (duration ?? 0) >= 10 }

    var durationText: String? {
        guard let duration else { return nil }
        if duration < 1 { return "<1s" }
        if duration < 60 { return String(format: "%.0fs", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
}

/// Per-session command history.
///
/// Commands are captured from the rendered prompt line at the moment Return is
/// pressed, not from a buffer of keystrokes: line editing, history recall and
/// tab completion all mean what was typed and what is about to run are
/// different strings. Reading the line the shell actually shows gets the real
/// command in every one of those cases.
@MainActor
final class CommandHistory: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    /// Kept bounded — a long-lived session would otherwise grow without limit.
    private let limit = 500

    var running: HistoryEntry? {
        entries.last.flatMap { $0.isRunning ? $0 : nil }
    }

    func begin(command: String, directory: String?) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A command still marked running when the next one starts never had its
        // completion observed; close it rather than leave it hanging forever.
        finishRunning()

        entries.append(HistoryEntry(command: trimmed, directory: directory, startedAt: Date()))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// Marks the running command finished. Returns it so the caller can decide
    /// whether it is worth announcing.
    @discardableResult
    func finishRunning(exitCode: Int32? = nil) -> HistoryEntry? {
        guard let index = entries.indices.last, entries[index].isRunning else { return nil }
        entries[index].finishedAt = Date()
        entries[index].exitCode = exitCode
        return entries[index]
    }

    func clear() { entries.removeAll() }

    func setTriage(_ text: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].triage = text
    }

    /// Most recent first, optionally filtered.
    func filtered(_ query: String) -> [HistoryEntry] {
        let ordered = entries.reversed()
        guard !query.isEmpty else { return Array(ordered) }
        let needle = query.lowercased()
        return ordered.filter { $0.command.lowercased().contains(needle) }
    }
}
