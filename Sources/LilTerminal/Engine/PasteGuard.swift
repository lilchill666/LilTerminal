import AppKit

/// Decides whether a paste deserves a confirmation.
///
/// The failure this prevents is specific: text copied from a web page or a chat
/// that ends in a newline executes the moment it lands, before you have read it.
/// Multi-line pastes and a short list of destructive commands are worth one
/// keypress of friction; everything else is not, because a guard that fires
/// constantly is a guard people learn to dismiss without reading.
enum PasteGuard {
    struct Verdict {
        var needsConfirmation: Bool
        var reason: String
    }

    /// Commands where a mistaken paste is expensive and often irreversible.
    private static let risky: [(pattern: String, reason: String)] = [
        ("rm -rf",        "deletes files recursively"),
        ("rm -fr",        "deletes files recursively"),
        ("sudo ",         "runs as root"),
        ("mkfs",          "formats a filesystem"),
        ("dd if=",        "writes raw disk data"),
        (":(){",          "fork bomb"),
        ("chmod -R 777",  "makes files world-writable"),
        ("git reset --hard", "discards uncommitted work"),
        ("git clean -fd", "deletes untracked files"),
        ("> /dev/sda",    "writes to a raw device"),
        ("curl ",         "downloads and may execute remote content"),
        ("wget ",         "downloads and may execute remote content"),
    ]

    static func evaluate(_ text: String, preferences: Preferences) -> Verdict {
        guard preferences.pasteGuardEnabled else {
            return Verdict(needsConfirmation: false, reason: "")
        }

        // A trailing newline is the dangerous case: it submits immediately.
        let submitsImmediately = text.hasSuffix("\n") || text.hasSuffix("\r")
        let lines = text.split(whereSeparator: \.isNewline).count

        if preferences.pasteGuardRiskyCommands {
            let haystack = text.lowercased()
            for entry in risky where haystack.contains(entry.pattern) {
                return Verdict(needsConfirmation: true,
                               reason: "Contains “\(entry.pattern.trimmingCharacters(in: .whitespaces))” — \(entry.reason).")
            }
        }

        if lines >= preferences.pasteGuardLineThreshold {
            return Verdict(
                needsConfirmation: true,
                reason: submitsImmediately
                    ? "\(lines) lines, and it ends with a newline — the last line runs immediately."
                    : "\(lines) lines will be sent to the shell.")
        }

        if submitsImmediately, lines == 1 {
            return Verdict(needsConfirmation: true,
                           reason: "Ends with a newline, so it runs immediately.")
        }

        return Verdict(needsConfirmation: false, reason: "")
    }

    /// Returns the text to paste, or nil if the user declined.
    @MainActor
    static func confirm(_ text: String, preferences: Preferences) -> String? {
        let verdict = evaluate(text, preferences: preferences)
        guard verdict.needsConfirmation else { return text }

        let alert = NSAlert()
        alert.messageText = "Paste into terminal?"
        alert.informativeText = verdict.reason
        alert.alertStyle = .warning

        // Show what is actually about to run — the guard is worthless if you
        // have to dismiss it to read the thing you are deciding about.
        let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
        preview.string = String(text.prefix(2000))
        preview.isEditable = false
        preview.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? text : nil
    }
}
