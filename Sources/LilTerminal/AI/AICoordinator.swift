import Foundation
import AppKit

/// Decides when the AI features should run, and what to do with the answers.
///
/// Kept separate from `Workspace` so the rules about *when not to call* live in
/// one readable place. It holds no strong reference to tabs or sessions —
/// everything is looked up by id at use time, so a closed tab cannot be kept
/// alive by an in-flight request.
@MainActor
final class AICoordinator: ObservableObject {
    @Published private(set) var status: String = "off"
    @Published private(set) var isAvailable = false

    private let service = AIService()
    private weak var workspace: Workspace?
    private var configuredSignature: String?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    // MARK: - Configuration

    /// Rebuilds the backend only when the relevant settings actually changed.
    func reconfigureIfNeeded() {
        guard let workspace else { return }
        let prefs = workspace.prefs
        let signature = "\(prefs.aiEnabled)|\(prefs.aiBackend.rawValue)|\(prefs.aiOllamaModel)"
        guard signature != configuredSignature else { return }
        configuredSignature = signature

        guard prefs.aiEnabled else {
            Task { await service.configure(nil, description: "off") }
            status = "off"
            isAvailable = false
            return
        }

        let backend: AIBackend
        switch prefs.aiBackend {
        case .appleOnDevice: backend = AppleOnDeviceBackend()
        case .ollama:        backend = OllamaBackend(model: prefs.aiOllamaModel)
        }

        Task { [weak self] in
            await self?.service.configure(backend, description: prefs.aiBackend.label)
            let problem = await self?.service.checkAvailability()
            await MainActor.run { [weak self] in
                self?.isAvailable = (problem == nil)
                self?.status = problem ?? "ready"
            }
        }
    }

    /// Re-runs the availability probe without rebuilding the backend.
    ///
    /// The backend is only reconfigured when settings change, so a server that
    /// starts afterwards would otherwise leave the status stale forever.
    func recheck() {
        guard let workspace, workspace.prefs.aiEnabled else { return }
        Task { [weak self] in
            let problem = await self?.service.checkAvailability()
            await MainActor.run { [weak self] in
                self?.isAvailable = (problem == nil)
                self?.status = problem ?? "ready"
            }
        }
    }

    func cancelAll() {
        Task { await service.cancelAll() }
    }

    func forget(tab: UUID) {
        Task { await service.forget(keyPrefix: "\(tab)") }
    }

    // MARK: - Driving

    /// Called once per metrics tick. Everything below is a filter.
    func tick() {
        guard let workspace, workspace.prefs.aiEnabled, isAvailable else { return }
        let prefs = workspace.prefs

        for tab in workspace.tabs {
            // Per-tab opt-out comes first: a tab you excluded is never read.
            guard tab.aiEnabled else { continue }
            // The tab in front of you does not need a label telling you what it
            // is doing — you can see it.
            if prefs.aiSkipFocusedTab, tab.id == workspace.selectedTabID, NSApp.isActive { continue }
            guard let session = tab.focused else { continue }

            if prefs.aiActivityEnabled {
                classifyActivity(tab: tab, session: session, cooldown: prefs.aiActivityCooldown)
            }
            if prefs.aiAutoNameEnabled {
                suggestName(tab: tab, session: session)
            }
        }
    }

    private func classifyActivity(tab: Tab, session: TerminalSession, cooldown: TimeInterval) {
        let output = AITasks.recentOutput(session.terminalView.visibleLines())
        guard !output.isEmpty else { return }

        let key = "\(tab.id)|activity"
        let hash = output.hashValue

        Task { [weak self, weak tab] in
            guard let self else { return }
            let response = await self.service.run(
                key: key, inputHash: hash, cooldown: cooldown,
                request: AITasks.activityRequest(output: output))
            guard let response, let tab else { return }
            let activity = AITasks.parseActivity(response)
            await MainActor.run {
                guard tab.activity != activity else { return }
                tab.activity = activity
                // A tab that needs you is worth a nudge, once.
                if activity.demandsAttention, !tab.hasUnseenOutput {
                    tab.hasUnseenOutput = true
                }
            }
        }
    }

    private func suggestName(tab: Tab, session: TerminalSession) {
        // A name the user chose is never overwritten.
        guard tab.customTitle == nil else { return }
        let commands = session.history.entries.suffix(6).map(\.command)
        // Nothing has been run yet: the directory is already the title, and a
        // model cannot do better than that from no evidence.
        guard !commands.isEmpty else { return }

        let key = "\(tab.id)|name"
        let hash = (session.workingDirectory ?? "").hashValue ^ commands.joined().hashValue

        Task { [weak self, weak tab] in
            guard let self else { return }
            let response = await self.service.run(
                key: key, inputHash: hash, cooldown: 90,
                request: AITasks.nameRequest(directory: session.workingDirectory,
                                             commands: commands))
            guard let response, let name = AITasks.parseName(response), let tab else { return }
            await MainActor.run {
                guard tab.customTitle == nil else { return }
                tab.suggestedName = name
            }
        }
    }

    // MARK: - Error triage

    /// Event-driven: only a command that finished and looks like it failed.
    func triage(entry: HistoryEntry, session: TerminalSession, tab: Tab) {
        guard let workspace, workspace.prefs.aiEnabled, workspace.prefs.aiTriageEnabled,
              isAvailable, tab.aiEnabled else { return }
        let output = AITasks.recentOutput(session.terminalView.visibleLines(), lines: 20)
        guard AITasks.looksLikeFailure(output) else { return }

        let entryID = entry.id
        Task { [weak self, weak session] in
            guard let self else { return }
            let response = await self.service.run(
                key: "\(tab.id)|triage|\(entryID)",
                inputHash: output.hashValue, cooldown: 0,
                request: AITasks.triageRequest(command: entry.command, output: output))
            guard let response, let text = AITasks.parseTriage(response) else { return }
            await MainActor.run { session?.history.setTriage(text, for: entryID) }
        }
    }

    // MARK: - Semantic search

    /// User-initiated, so it skips the gates — but it is still one call per
    /// search, debounced by the caller.
    func searchHistory(query: String, in history: CommandHistory) async -> [HistoryEntry]? {
        guard let workspace, workspace.prefs.aiEnabled, workspace.prefs.aiSearchEnabled,
              isAvailable, query.count >= 3 else { return nil }

        let candidates = Array(history.filtered("").prefix(80))
        guard !candidates.isEmpty else { return nil }

        let response = await service.runOnce(
            request: AITasks.searchRequest(query: query, commands: candidates.map(\.command)))
        guard let response else { return nil }
        let indices = AITasks.parseSearch(response, count: candidates.count)
        guard !indices.isEmpty else { return [] }
        return indices.map { candidates[$0] }
    }
}
