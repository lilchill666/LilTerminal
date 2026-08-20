import Foundation

/// What a tab appears to be doing, as judged from its recent output.
enum TabActivity: String, Codable {
    case working          // a command is running and progressing
    case waitingForInput  // sitting at a prompt or asking a question
    case finished         // last command completed
    case failed           // last command errored
    case unknown

    var label: String {
        switch self {
        case .working:         return "working"
        case .waitingForInput: return "needs you"
        case .finished:        return "done"
        case .failed:          return "failed"
        case .unknown:         return ""
        }
    }

    var icon: String? {
        switch self {
        case .working:         return "circle.dotted"
        case .waitingForInput: return "hand.raised.fill"
        case .finished:        return "checkmark"
        case .failed:          return "exclamationmark.triangle.fill"
        case .unknown:         return nil
        }
    }

    /// Only this one is worth pulling your attention.
    var demandsAttention: Bool { self == .waitingForInput || self == .failed }
}

/// Prompt construction and response parsing for the AI features.
///
/// Every task asks for one short, constrained answer. Small local models are
/// reliable at labelling and unreliable at prose, so nothing here asks for
/// prose longer than a sentence, and every response is parsed defensively —
/// a model that ignores the format must degrade to "unknown", never to a
/// wrong-but-confident label.
enum AITasks {

    // MARK: 1. Tab activity

    static func activityRequest(output: String) -> AIRequest {
        AIRequest(
            system: """
            You label terminal sessions. Answer with exactly one word from this \
            list and nothing else: working, waiting, done, failed.
            working = a command is running or producing progress output.
            waiting = the session is idle at a shell prompt, or a program is \
            asking the user a question.
            done = the last command completed successfully.
            failed = the last command reported an error.
            """,
            prompt: "Terminal output:\n\(output)\n\nOne word:",
            maxTokens: 5)
    }

    static func parseActivity(_ response: String) -> TabActivity {
        let text = response.lowercased()
        // Substring rather than equality: a small model will happily answer
        // "working." or "The session is working".
        if text.contains("waiting") { return .waitingForInput }
        if text.contains("failed") || text.contains("error") { return .failed }
        if text.contains("working") || text.contains("running") { return .working }
        if text.contains("done") || text.contains("complete") { return .finished }
        return .unknown
    }

    // MARK: 2. Tab name

    static func nameRequest(directory: String?, commands: [String]) -> AIRequest {
        let recent = commands.suffix(6).joined(separator: "\n")
        return AIRequest(
            system: """
            You name terminal tabs. Reply with a title of at most three words, \
            lowercase, no punctuation, no quotes, describing what this session \
            is for. Never explain. Never repeat the directory name alone.
            """,
            prompt: """
            Directory: \(directory ?? "unknown")
            Recent commands:
            \(recent.isEmpty ? "(none)" : recent)

            Title:
            """,
            maxTokens: 12)
    }

    static func parseName(_ response: String) -> String? {
        var name = response
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Models often answer with a sentence; keep the first line only.
        name = name.split(separator: "\n").first.map(String.init) ?? name
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".:- "))
        let words = name.split(separator: " ")
        guard !words.isEmpty, words.count <= 5, name.count <= 32 else { return nil }
        return name.lowercased()
    }

    // MARK: 3. Error triage

    /// Heuristic pre-filter. Asking the model about every completed command
    /// would be the definition of a pointless call, so text that shows no sign
    /// of failure never reaches it.
    static func looksLikeFailure(_ output: String) -> Bool {
        let markers = ["error", "failed", "fatal", "not found", "no such file",
                       "exception", "traceback", "panic:", "cannot find",
                       "permission denied", "command not found"]
        let text = output.lowercased()
        return markers.contains { text.contains($0) }
    }

    static func triageRequest(command: String, output: String) -> AIRequest {
        AIRequest(
            system: """
            You explain terminal failures. Reply with one short sentence naming \
            the cause, and a fix if it is obvious. No preamble, no markdown, \
            under 20 words.
            """,
            prompt: """
            Command: \(command)
            Output:
            \(output)

            Cause:
            """,
            maxTokens: 48)
    }

    static func parseTriage(_ response: String) -> String? {
        let text = response
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, text.count > 3, text.count < 200 else { return nil }
        return text
    }

    // MARK: 4. Semantic history search

    static func searchRequest(query: String, commands: [String]) -> AIRequest {
        let numbered = commands.enumerated()
            .map { "\($0.offset): \($0.element)" }
            .joined(separator: "\n")
        return AIRequest(
            system: """
            You match shell commands to a description. Reply with only the \
            numbers of matching commands, most relevant first, comma separated, \
            at most 8. If none match, reply none.
            """,
            prompt: """
            Description: \(query)

            Commands:
            \(numbered)

            Numbers:
            """,
            maxTokens: 32)
    }

    static func parseSearch(_ response: String, count: Int) -> [Int] {
        guard !response.lowercased().contains("none") else { return [] }
        // Pull every integer out rather than trusting the separator.
        let numbers = response.split { !$0.isNumber }.compactMap { Int($0) }
        var seen = Set<Int>()
        return numbers.filter { $0 >= 0 && $0 < count && seen.insert($0).inserted }
    }

    /// The tail of the visible screen, which is all any of these tasks needs.
    /// Sending a full scrollback would be slower, costlier, and no more useful.
    static func recentOutput(_ rows: [String], lines: Int = 16, characters: Int = 1400) -> String {
        let tail = rows.suffix(lines)
            .map { String($0.reversed().drop { $0 == " " }.reversed()) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(tail.suffix(characters))
    }
}
