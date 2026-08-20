import Foundation
import SwiftUI
import AppKit

/// One pane: a live shell, its terminal view, and everything we display about it.
///
/// The view is owned here and kept alive for the whole session, so switching
/// tabs is a reparent rather than a teardown. A SwiftUI-rebuilt terminal would
/// lose scrollback and kill the shell.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published var title: String
    /// True once the user renames it; stops the shell's title escapes overwriting.
    @Published var titleIsCustom = false
    @Published var workingDirectory: String?
    @Published var metrics: SessionMetrics = .zero
    @Published var isRunning = true
    @Published var exitCode: Int32?
    @Published var git: GitInfo?

    let shell: Shell
    let terminalView: GhosttyTerminalView
    let startedAt = Date()
    let history = CommandHistory()
    /// Set while a child process is running, used to detect completion.
    private(set) var hadForegroundProcess = false

    /// Last time the user actually typed here — drives the background heuristic,
    /// which is about human attention, not process activity.
    private(set) var lastInteraction = Date()

    var shellPid: pid_t { terminalView.childPID }

    /// Idle for a while but still running children: exactly the case the user
    /// wants filed out of the way.
    var looksLikeBackgroundJob: Bool {
        guard isRunning else { return false }
        return Date().timeIntervalSince(lastInteraction) > 120 && metrics.processCount > 1
    }

    /// Stable across launches when sessions are persistent, so the daemon can
    /// be asked for this exact shell again.
    let persistentID: String

    init?(shell: Shell, workingDirectory: String? = nil, font: NSFont,
          persistentID: String? = nil, transport: TerminalTransport? = nil) {
        self.persistentID = persistentID ?? UUID().uuidString
        guard let view = GhosttyTerminalView(font: font, transport: transport) else { return nil }
        self.shell = shell
        self.title = shell.name
        self.workingDirectory = workingDirectory
        self.terminalView = view

        view.onUserInput = { [weak self] in self?.noteInteraction() }
        view.resolveDirectory = { [weak self] in self?.workingDirectory }
        view.onCommandSubmitted = { [weak self] command in
            guard let self else { return }
            self.history.begin(command: command, directory: self.workingDirectory)
        }
    }

    func start(in directory: String?) {
        // The user's real environment plus TERM, so capability probes and
        // anything reading PATH behave as they do in Terminal.app.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "LilTerminal"
        environment["COLORTERM"] = "truecolor"
        let entries = environment.map { "\($0.key)=\($0.value)" }

        do {
            try terminalView.start(
                executable: shell.path,
                args: shell.loginArgs,
                environment: entries,
                // A leading dash in argv[0] marks a login shell, which is what
                // zsh and fish check before reading profile files.
                execName: "-" + shell.name,
                directory: directory ?? workingDirectory
            )
        } catch {
            isRunning = false
            exitCode = nil
        }
    }

    func noteInteraction() {
        lastInteraction = Date()
    }

    /// Called after each metrics sample.
    ///
    /// The process tree already tells us when a child appears and disappears,
    /// so command completion is observable without any shell cooperation —
    /// which matters because most people never install shell integration.
    /// Returns the finished command when one just completed.
    /// Refreshes the git branch for this session's directory.
    func refreshGit() {
        guard let directory = workingDirectory else { return }
        Task { [weak self] in
            let info = await GitStatusCache.shared.status(for: directory)
            await MainActor.run { [weak self] in
                guard let self, self.git != info else { return }
                self.git = info
            }
        }
    }

    @discardableResult
    func reconcileForegroundProcess() -> HistoryEntry? {
        let hasForeground = metrics.processCount > 1
        defer { hadForegroundProcess = hasForeground }
        guard hadForegroundProcess, !hasForeground else { return nil }
        return history.finishRunning()
    }

    /// Push bytes to the shell as if typed.
    func send(_ bytes: [UInt8]) {
        noteInteraction()
        terminalView.send(bytes)
    }

    func send(text: String) { send(Array(text.utf8)) }

    func terminate() {
        guard isRunning else { return }
        terminalView.terminate()
        isRunning = false
    }

    /// Leaves the shell running in the daemon.
    func detach() {
        terminalView.detach()
    }
}
