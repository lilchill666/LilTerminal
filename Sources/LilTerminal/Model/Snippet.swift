import Foundation

/// A canned bit of text sent to the focused terminal, optionally with a
/// trailing newline so it runs immediately.
struct Snippet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var text: String
    /// Append \n so the command executes rather than just sitting on the prompt.
    var runsImmediately: Bool = true
    /// Single character; the binding is Control-Option-<key>. Empty = unbound.
    var key: String = ""
    /// Groups snippets in the library. Empty means uncategorised.
    var folder: String = ""
    /// Long prompts are stored as-is; `text` may span many lines.
    var isPrompt: Bool = false

    /// `{}` in the text marks where the cursor should end up. Because a PTY has
    /// no "set cursor" concept, we emulate it: send the whole line, then send
    /// that many ASCII-left-arrows to walk back into the placeholder.
    var placeholderRange: (prefix: String, suffix: String)? {
        guard let r = text.range(of: "{}") else { return nil }
        return (String(text[text.startIndex..<r.lowerBound]),
                String(text[r.upperBound...]))
    }

    /// Bytes to send for this snippet, including any cursor repositioning.
    func keystrokes() -> [UInt8] {
        if let (prefix, suffix) = placeholderRange {
            // Never auto-run a snippet that wants input: the whole point of the
            // placeholder is that the user still has something to type.
            var bytes = Array((prefix + suffix).utf8)
            bytes.append(contentsOf: Array(repeating: [0x1b, 0x5b, 0x44], count: suffix.count).flatMap { $0 })
            return bytes
        }
        var bytes = Array(text.utf8)
        if runsImmediately { bytes.append(0x0d) }
        return bytes
    }

    /// The git flow the user runs constantly, plus a couple of near-neighbours.
    static let starterPack: [Snippet] = [
        Snippet(name: "Stage all",   text: "git add -A",                    key: "a", folder: "Git"),
        Snippet(name: "Commit",      text: "git commit -m \"{}\"",          key: "c", folder: "Git"),
        Snippet(name: "Push",        text: "git push",                      key: "p", folder: "Git"),
        Snippet(name: "Add + commit + push",
                text: "git add -A && git commit -m \"{}\" && git push",     key: "g", folder: "Git"),
        Snippet(name: "Status",      text: "git status --short --branch",   key: "s", folder: "Git"),
        Snippet(name: "Log (graph)", text: "git log --oneline --graph -20", key: "l", folder: "Git"),
        Snippet(name: "Diff staged", text: "git diff --staged",             key: "d", folder: "Git"),

        // Prompts are snippets that happen to be prose. Keeping them in one
        // system means one editor, one store, one set of bindings.
        Snippet(name: "Review this diff",
                text: "Review the changes on this branch for correctness bugs and simplifications. Be specific about failure cases.",
                runsImmediately: false, key: "", folder: "Prompts", isPrompt: true),
        Snippet(name: "Explain this code",
                text: "Explain what {} does, and call out anything surprising or risky about it.",
                runsImmediately: false, key: "", folder: "Prompts", isPrompt: true),
        Snippet(name: "Write tests",
                text: "Write tests for {}. Cover the edge cases that would actually break it, not just the happy path.",
                runsImmediately: false, key: "", folder: "Prompts", isPrompt: true),
    ]
}
