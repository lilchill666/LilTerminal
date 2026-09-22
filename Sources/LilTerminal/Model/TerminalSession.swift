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
        view.onKeystroke = { isReturn in
            // Reads preferences at press time rather than caching them, so the
            // setting takes effect immediately and a disabled feature costs one
            // boolean check per key.
            guard let prefs = Workspace.current?.prefs, prefs.typingSounds else { return }
            TypingSounds.shared.play(isReturn: isReturn, volume: prefs.typingSoundVolume)
        }
        view.resolveDirectory = { [weak self] in self?.workingDirectory }
        view.onCommandSubmitted = { [weak self] command in
            guard let self else { return }
            self.history.begin(command: command, directory: self.workingDirectory)
        }
    }

    func start(in directory: String?) {
        let entries = Self.shellEnvironment(for: shell).map { "\($0.key)=\($0.value)" }

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

    /// The environment a shell is started with.
    ///
    /// Deliberately *not* this process's environment. A terminal launched from
    /// another program inherits that program's variables, and passing them on
    /// hands every tab a private environment that has nothing to do with the
    /// user: launch LilTerminal from a tool that exports its own state and each
    /// shell — and everything run in it — believes it is running inside that
    /// tool. That is not what Terminal.app does, whatever the old comment here
    /// claimed; it starts a login shell in a clean session.
    ///
    /// So only what identifies the user and the terminal is passed through. The
    /// login shell builds the rest, which is its job: `/etc/zprofile` runs
    /// `path_helper`, and the user's own profile runs after it.
    static func shellEnvironment(for shell: Shell) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": shell.path,
            // A starting point only; path_helper rebuilds this from
            // /etc/paths and /etc/paths.d before the user's profile runs.
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "TERM_PROGRAM": "LilTerminal",
            "TERM_PROGRAM_VERSION": Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "COLORTERM": "truecolor",
        ]

        // Carried over when present: these describe the user's session rather
        // than whatever happened to launch the app.
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SSH_AUTH_SOCK",
                    "__CF_USER_TEXT_ENCODING"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
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

    /// Text arriving as a block — a snippet, a history entry, a dropped path.
    /// Bracketed so the program can tell it from someone typing very fast.
    func send(paste text: String) {
        noteInteraction()
        terminalView.send(paste: text)
    }

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
