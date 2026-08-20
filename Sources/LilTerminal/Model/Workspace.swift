import Foundation
import SwiftUI
import AppKit
import Combine

/// A user-created collection of tabs in the sidebar.
struct TabGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var isCollapsed = false
    /// A locked group refuses to close or dissolve without confirmation.
    var isLocked = false
    /// Marks the group auto-file puts background jobs into.
    var isAutoBackground = false
}

/// The whole app state: tabs, groups, snippets, themes, and metric plumbing.
@MainActor
final class Workspace: NSObject, ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published var groups: [TabGroup] = []
    @Published var selectedTabID: UUID?
    @Published var snippets: [Snippet] = []
    @Published var availableShells: [Shell] = []
    @Published var autoFileBackgroundJobs = true
    @Published var sidebarVisible = true
    @Published var inspectorVisible = false
    /// Sidebar filter text.
    @Published var tabFilter = ""
    @Published var tabFilterFocused = false
    /// Locks the whole app: quitting asks for confirmation.
    @Published var appIsLocked = SettingsStore.shared.document.appIsLocked {
        didSet { SettingsStore.shared.update { $0.appIsLocked = appIsLocked } }
    }
    @Published var prefs = SettingsStore.shared.document.preferences { didSet { onPrefsChanged(oldValue) } }
    /// Decoded once and cached; re-reading the file every frame would be absurd.
    @Published private(set) var backgroundImage: NSImage?

    let themes = ThemeStore()
    private(set) lazy var ai = AICoordinator(workspace: self)

    private let sampler = ProcessSampler()
    /// Maps a terminal view back to its session for delegate callbacks.
    private var sessionsByView: [ObjectIdentifier: TerminalSession] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var inputMonitor: Any?
    /// Lets the app delegate save on quit without threading a reference through.
    static weak var current: Workspace?

    /// Font settings live in Preferences; this keeps the old call sites honest.
    var fontSize: CGFloat { CGFloat(prefs.fontSize) }

    /// Nil disables the animation entirely, which is what the "animations off"
    /// preference has to do — a zero-duration animation still animates.
    func anim(_ base: Animation) -> Animation? {
        prefs.animationsEnabled ? base.speed(prefs.animationSpeed) : nil
    }

    private func onPrefsChanged(_ old: Preferences) {
        SettingsStore.shared.update { $0.preferences = prefs }
        ai.reconfigureIfNeeded()
        if old.fontName != prefs.fontName || old.fontSize != prefs.fontSize
            || old.terminalOpacity != prefs.terminalOpacity {
            refreshTheme()
        }
        if old.backgroundImagePath != prefs.backgroundImagePath {
            reloadBackgroundImage()
        }
    }

    private func reloadBackgroundImage() {
        guard let path = prefs.backgroundImagePath else { backgroundImage = nil; return }
        backgroundImage = NSImage(contentsOfFile: path)
        // A path that no longer resolves is cleared rather than left dangling,
        // so the settings UI stops claiming an image is set.
        if backgroundImage == nil { prefs.backgroundImagePath = nil }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.backgroundImagePath = url.path
        if prefs.backgroundMode != .image { prefs.backgroundMode = .image }
    }

    func clearBackgroundImage() {
        prefs.backgroundImagePath = nil
        if prefs.backgroundMode == .image { prefs.backgroundMode = .solid }
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }
    var focusedSession: TerminalSession? { selectedTab?.focused }

    /// Does this tab survive the sidebar filter? Matches the title, the branch
    /// and the directory, because any of the three is a thing you might
    /// remember a tab by.
    func matchesFilter(_ tab: Tab) -> Bool {
        guard !tabFilter.isEmpty else { return true }
        let needle = tabFilter.lowercased()
        if tab.displayTitle.lowercased().contains(needle) { return true }
        if let branch = tab.focused?.git?.branch.lowercased(), branch.contains(needle) { return true }
        if let dir = tab.focused?.workingDirectory?.lowercased(), dir.contains(needle) { return true }
        if tab.activity.label.contains(needle) { return true }
        return false
    }

    var isFilterVisible: Bool {
        prefs.showTabFilter && (tabs.count >= prefs.tabFilterThreshold || !tabFilter.isEmpty || tabFilterFocused)
    }

    var ungroupedTabs: [Tab] {
        let loose = tabs.filter { $0.groupID == nil && matchesFilter($0) }
        // A stable partition, so pinning does not otherwise reorder anything.
        return loose.filter(\.isPinned) + loose.filter { !$0.isPinned }
    }
    func tabs(in group: TabGroup) -> [Tab] {
        tabs.filter { $0.groupID == group.id && matchesFilter($0) }
    }

    var allSessions: [TerminalSession] { tabs.flatMap(\.sessions) }

    override init() {
        super.init()
        availableShells = ShellCatalog.discover()
        snippets = SettingsStore.shared.document.snippets
        groups = SettingsStore.shared.document.groups
        sampler.rootProvider = { [weak self] in
            guard let self else { return [] }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.allSessions.compactMap { $0.isRunning ? $0.shellPid : nil }
                }
            }
        }
        sampler.onSample = { [weak self] samples in
            MainActor.assumeIsolated { self?.applyMetrics(samples) }
        }
        // ThemeStore is its own ObservableObject, so views watching Workspace
        // would never hear about a theme change and the chrome would keep the
        // old palette while the terminals repainted. Forward its changes.
        themes.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        sampler.start()
        ai.reconfigureIfNeeded()
        installInputMonitor()
        reloadBackgroundImage()
        Workspace.current = self
    }

    /// One monitor rather than a TerminalView subclass: `keyDown` is not open
    /// in SwiftTerm, and a single hook that resolves the first responder covers
    /// keys, clicks, and every pane at once.
    private func installInputMonitor() {
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                if let responder = event.window?.firstResponder as? GhosttyTerminalView,
                   let session = self.sessionsByView[ObjectIdentifier(responder)] {
                    session.noteInteraction()
                    if let tab = self.tab(containing: session.id), tab.hasUnseenOutput {
                        tab.hasUnseenOutput = false
                    }
                }
            }
            return event
        }
    }

    func tab(containing sessionID: UUID) -> Tab? {
        tabs.first { $0.sessions.contains { $0.id == sessionID } }
    }

    private func applyMetrics(_ samples: [pid_t: SessionMetrics]) {
        for session in allSessions {
            guard session.isRunning, let metrics = samples[session.shellPid] else { continue }
            if session.metrics != metrics { session.metrics = metrics }
            // The sampler is the authority on the directory now, not OSC 7.
            if let directory = metrics.workingDirectory, session.workingDirectory != directory {
                session.workingDirectory = directory
            }
        }
        // A command that just finished is worth announcing; the process tree
        // is what tells us, so this rides along with the metrics sample.
        for session in allSessions {
            if prefs.showGitBranch { session.refreshGit() }
            if let finished = session.reconcileForegroundProcess() {
                announceIfWorthwhile(finished, in: session)
                if let tab = tab(containing: session.id) {
                    ai.triage(entry: finished, session: session, tab: tab)
                }
            }
        }

        // Tab aggregates are computed, so nudge tab observers explicitly.
        for tab in tabs { tab.objectWillChange.send() }
        WindowConfigurator.enforceTrafficLights()
        ai.tick()
        if autoFileBackgroundJobs { autoFileIfNeeded() }
    }

    /// Moves long-idle busy tabs into the Background group — the actual fix for
    /// "background jobs clutter the tab list".
    private func autoFileIfNeeded() {
        let candidates = tabs.filter { $0.groupID == nil && $0.looksLikeBackgroundJob }
        guard !candidates.isEmpty else { return }
        let group = ensureBackgroundGroup()
        for tab in candidates { tab.groupID = group.id }
        objectWillChange.send()
    }

    @discardableResult
    private func ensureBackgroundGroup() -> TabGroup {
        if let existing = groups.first(where: { $0.isAutoBackground }) { return existing }
        let group = TabGroup(name: "Background", isCollapsed: true, isAutoBackground: true)
        groups.append(group)
        SettingsStore.shared.update { $0.groups = groups }
        return group
    }

    // MARK: - Session plumbing

    /// Builds a session, backed by the daemon when persistence is on.
    ///
    /// - Parameter persistentID: when supplied and the daemon already has a
    ///   live session with that id, the shell is reattached rather than started
    ///   again — that is what survives a quit.
    private func makeSession(shell: Shell?, directory: String?,
                             persistentID: String? = nil) -> TerminalSession {
        let chosen = shell ?? availableShells.first ?? ShellCatalog.default
        let cwd = directory
            ?? focusedSession?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        var transport: TerminalTransport?
        var identifier = persistentID
        if prefs.persistentSessions, DaemonClient.shared.connectIfNeeded() {
            let id = persistentID ?? UUID().uuidString
            identifier = id
            transport = DaemonTransport(id: id, client: DaemonClient.shared,
                                        existing: DaemonClient.shared.hasSession(id: id))
        }

        guard let session = TerminalSession(
            shell: chosen, workingDirectory: cwd,
            font: Theme.monoFont(size: fontSize, name: prefs.fontName),
            persistentID: identifier, transport: transport
        ) else {
            fatalError("failed to create a terminal session")
        }
        sessionsByView[ObjectIdentifier(session.terminalView)] = session

        session.terminalView.onTitleChange = { [weak session] title in
            guard let session, !session.titleIsCustom, !title.isEmpty else { return }
            session.title = title
        }
        session.terminalView.onDirectoryChange = { [weak session] directory in
            session?.workingDirectory = directory
        }
        session.terminalView.onExit = { [weak self, weak session] code in
            guard let session else { return }
            session.isRunning = false
            session.exitCode = code
            session.metrics = .zero
            self?.objectWillChange.send()
        }
        Theme.apply(themes.active, to: session.terminalView, fontSize: fontSize,
                    fontName: prefs.fontName, opacity: prefs.terminalOpacity,
                        inset: CGFloat(prefs.terminalPadding))

        session.terminalView.pasteFilter = { [weak self] text in
            guard let self else { return text }
            return PasteGuard.confirm(text, preferences: self.prefs)
        }
        session.terminalView.onOutput = { [weak self] in
            MainActor.assumeIsolated { self?.noteOutput(from: session.id) }
        }

        session.start(in: cwd)
        return session
    }

    private func noteOutput(from sessionID: UUID) {
        guard let tab = tab(containing: sessionID) else { return }
        // A shell prints its prompt the moment it starts, so without this every
        // restored tab would come back already flagged as having new output.
        if let session = tab.sessions.first(where: { $0.id == sessionID }),
           Date().timeIntervalSince(session.startedAt) < 2 { return }
        // Only unselected tabs earn the marker; output in the tab you are
        // looking at is not news.
        guard tab.id != selectedTabID, !tab.hasUnseenOutput else { return }
        tab.hasUnseenOutput = true
    }

    // MARK: - Notifications

    /// Announces a finished command when it ran long enough to be worth
    /// interrupting for.
    ///
    /// The bar is deliberately high: a notification for every `ls` would train
    /// you to ignore them, which defeats the point for the long build you
    /// actually walked away from.
    private func announceIfWorthwhile(_ entry: HistoryEntry, in session: TerminalSession) {
        guard prefs.notificationsEnabled,
              let duration = entry.duration,
              duration >= prefs.notifyAfterSeconds else { return }

        guard let tab = tab(containing: session.id) else { return }

        // A tab you are already watching does not need announcing.
        let isWatching = tab.id == selectedTabID
            && NSApp.isActive
            && tab.focusedSessionID == session.id
        if prefs.notifyOnlyWhenUnfocused && isWatching { return }

        tab.finishedCommand = entry
        tab.hasUnseenOutput = true
        Notifier.post(title: "\(tab.displayTitle) finished",
                      body: "\(entry.command)  ·  \(entry.durationText ?? "")")
    }

    // MARK: - Find

    /// Bumped to ask the visible find bar to step; the bar owns the term, so
    /// the menu only needs to say "again, this direction".
    @Published var findTrigger = 0
    var findForward = true

    func find(_ action: NSFindPanelAction) {
        switch action {
        case .showFindPanel:
            NotificationCenter.default.post(name: .openFind, object: nil)
        case .next:
            findForward = true
            findTrigger += 1
        case .previous:
            findForward = false
            findTrigger += 1
        case .setFindString:
            NotificationCenter.default.post(name: .openFind, object: nil)
        default:
            break
        }
    }


    // MARK: - Tabs

    @discardableResult
    func newTab(shell: Shell? = nil, in group: UUID? = nil) -> Tab {
        let session = makeSession(shell: shell, directory: nil)
        let tab = Tab(session: session)
        tab.groupID = group
        tabs.append(tab)
        selectedTabID = tab.id
        saveLayout()
        return tab
    }

    /// Closing anything locked asks first. Locks exist precisely to stop a
    /// stray ⌘W from killing a long-running job, so the guard lives here rather
    /// than in each call site.
    func confirmClose(_ tab: Tab) -> Bool {
        let groupLocked = tab.groupID.flatMap { id in groups.first { $0.id == id }?.isLocked } ?? false
        guard tab.isLocked || groupLocked else { return true }

        let alert = NSAlert()
        alert.messageText = "Close “\(tab.displayTitle)”?"
        alert.informativeText = tab.isLocked
            ? "This tab is locked. Closing it will end everything running in it."
            : "This tab is in a locked group. Closing it will end everything running in it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func requestClose(_ tab: Tab) {
        guard confirmClose(tab) else { return }
        close(tab)
    }

    func confirmDissolve(_ group: TabGroup) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Ungroup “\(group.name)”?"
        alert.informativeText = "This group is locked. Its tabs will stay open but leave the group."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ungroup")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func togglePin(_ tab: Tab) {
        tab.isPinned.toggle()
        objectWillChange.send()
        saveLayout()
    }

    func toggleLock(_ tab: Tab) {
        tab.isLocked.toggle()
        objectWillChange.send()
        saveLayout()
    }

    func toggleLock(group: TabGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].isLocked.toggle()
        SettingsStore.shared.update { $0.groups = groups }
    }

    /// True when quitting would tear down something the user protected.
    var hasLockedWork: Bool {
        if appIsLocked { return true }
        if tabs.contains(where: { $0.isLocked }) { return true }
        return groups.contains { group in group.isLocked && !tabs(in: group).isEmpty }
    }

    func close(_ tab: Tab) {
        tab.terminateAll()
        for session in tab.sessions {
            sessionsByView.removeValue(forKey: ObjectIdentifier(session.terminalView))
        }
        let index = tabs.firstIndex { $0.id == tab.id }
        // Drop any AI bookkeeping for this tab so it cannot accumulate.
        ai.forget(tab: tab.id)
        tabs.removeAll { $0.id == tab.id }

        if selectedTabID == tab.id {
            let fallback = min(index ?? 0, tabs.count - 1)
            selectedTabID = tabs.indices.contains(fallback) ? tabs[fallback].id : nil
        }
        saveLayout()
    }

    func closeSelectedTab() {
        if let selectedTab { requestClose(selectedTab) }
    }

    func select(_ tab: Tab) {
        selectedTabID = tab.id
        tab.hasUnseenOutput = false
        tab.focused?.noteInteraction()
    }

    // MARK: - Splits

    func split(axis: SplitAxis, shell: Shell? = nil) {
        guard let tab = selectedTab, let target = tab.focused else { return }
        let session = makeSession(shell: shell, directory: target.workingDirectory)
        tab.add(session, splitting: target.id, axis: axis)
    }

    /// Closes just the focused pane; closes the whole tab if it was the last one.
    func closeFocusedPane() {
        guard let tab = selectedTab, let focused = tab.focused else { return }
        guard tab.isSplit else { close(tab); return }

        sessionsByView.removeValue(forKey: ObjectIdentifier(focused.terminalView))
        if !tab.remove(focused.id) { close(tab) }
    }

    func focusPane(_ offset: Int) {
        selectedTab?.focusNextPane(offset)
    }

    func focus(_ session: TerminalSession, in tab: Tab) {
        if selectedTabID != tab.id { selectedTabID = tab.id }
        tab.focusedSessionID = session.id
        session.noteInteraction()
    }

    // MARK: - Ordering and selection

    /// Visible order, matching the sidebar top to bottom so cycling moves to
    /// the tab the user can see is next.
    var visualOrder: [Tab] {
        var ordered = ungroupedTabs
        for group in groups where !group.isCollapsed { ordered.append(contentsOf: tabs(in: group)) }
        for group in groups where group.isCollapsed { ordered.append(contentsOf: tabs(in: group)) }
        return ordered
    }

    func cycleSelection(by offset: Int) {
        let ordered = visualOrder
        guard !ordered.isEmpty else { return }
        guard let current = ordered.firstIndex(where: { $0.id == selectedTabID }) else {
            select(ordered[0]); return
        }
        let next = ((current + offset) % ordered.count + ordered.count) % ordered.count
        select(ordered[next])
    }

    func selectIndex(_ index: Int) {
        let ordered = visualOrder
        guard ordered.indices.contains(index) else { return }
        select(ordered[index])
    }

    // MARK: - Groups

    @discardableResult
    func addGroup(named name: String = "New Group") -> TabGroup {
        let group = TabGroup(name: name)
        groups.append(group)
        SettingsStore.shared.update { $0.groups = groups }
        return group
    }

    func rename(group: TabGroup, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = name
        SettingsStore.shared.update { $0.groups = groups }
    }

    func toggleCollapse(_ group: TabGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].isCollapsed.toggle()
        SettingsStore.shared.update { $0.groups = groups }
    }

    /// Removes the group but keeps its tabs, which become ungrouped.
    func dissolve(_ group: TabGroup) {
        for tab in tabs(in: group) { tab.groupID = nil }
        groups.removeAll { $0.id == group.id }
        SettingsStore.shared.update { $0.groups = groups }
        objectWillChange.send()
    }

    func move(_ tab: Tab, to group: TabGroup?) {
        tab.groupID = group?.id
        objectWillChange.send()
        saveLayout()
    }

    /// Reorders within the sidebar, optionally re-homing the tab into the
    /// group it was dropped in.
    func moveTab(_ dragged: Tab, before target: Tab?, group: UUID?) {
        guard let from = tabs.firstIndex(where: { $0.id == dragged.id }) else { return }
        dragged.groupID = group

        var reordered = tabs
        reordered.remove(at: from)

        let insertion: Int
        if let target, let position = reordered.firstIndex(where: { $0.id == target.id }) {
            insertion = position
        } else if let group {
            // Dropped on a group header or its empty space: append to that group.
            insertion = reordered.lastIndex { $0.groupID == group }.map { $0 + 1 } ?? reordered.count
        } else {
            insertion = reordered.lastIndex { $0.groupID == nil }.map { $0 + 1 } ?? 0
        }

        reordered.insert(dragged, at: min(insertion, reordered.count))
        tabs = reordered
        saveLayout()
    }

    /// Shared by every drop target: resolves the dragged id and rejects
    /// no-op drops so SwiftUI does not animate a move that did not happen.
    func acceptDrop(_ items: [String], before target: Tab?, group: UUID?) -> Bool {
        guard let raw = items.first,
              let id = UUID(uuidString: raw),
              let dragged = tabs.first(where: { $0.id == id }),
              dragged.id != target?.id else { return false }
        withAnimation(anim(.paneMove)) {
            moveTab(dragged, before: target, group: group)
        }
        return true
    }

    func rename(_ tab: Tab, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        saveLayout()
    }

    func toggleZoom() {
        guard let tab = selectedTab else { return }
        tab.toggleZoom()
    }

    // MARK: - Session restore

    /// Leaves shells running instead of killing them, for quit with
    /// persistence on.
    func detachAll() {
        for session in allSessions { session.detach() }
    }

    /// Saves the shape of the workspace — tabs, groups, panes, directories —
    /// but never what was running. Re-running a command on launch would be
    /// surprising and occasionally destructive.
    func saveLayout() {
        guard prefs.restoreSessions else { return }
        let snapshots: [TabSnapshot] = tabs.compactMap { tab in
            var index: [UUID: Int] = [:]
            var panes: [PaneSnapshot] = []
            for (position, session) in tab.sessions.enumerated() {
                index[session.id] = position
                panes.append(PaneSnapshot(shellPath: session.shell.path,
                                          workingDirectory: session.workingDirectory,
                                          persistentID: session.persistentID))
            }
            guard !panes.isEmpty, let layout = tab.root.snapshot(index: index) else { return nil }
            return TabSnapshot(groupID: tab.groupID, customTitle: tab.customTitle,
                               panes: panes, layout: layout,
                               isPinned: tab.isPinned, isLocked: tab.isLocked,
                               aiEnabled: tab.aiEnabled)
        }
        let selected = tabs.firstIndex { $0.id == selectedTabID }
        Persistence.saveLayout(WorkspaceSnapshot(tabs: snapshots, selectedIndex: selected))
    }

    /// Returns false when there was nothing to restore, so the caller can open
    /// a fresh tab instead.
    @discardableResult
    func restoreLayout() -> Bool {
        guard prefs.restoreSessions,
              let snapshot = Persistence.loadLayout(), !snapshot.tabs.isEmpty else { return false }

        let knownGroups = Set(groups.map(\.id))

        for saved in snapshot.tabs {
            var sessions: [TerminalSession] = []
            for pane in saved.panes {
                let shell = availableShells.first { $0.path == pane.shellPath }
                    ?? ShellCatalog.default
                // A directory that no longer exists would fail the spawn, so
                // fall back to home rather than losing the pane.
                let directory = pane.workingDirectory.flatMap {
                    FileManager.default.fileExists(atPath: $0) ? $0 : nil
                } ?? FileManager.default.homeDirectoryForCurrentUser.path
                sessions.append(makeSession(shell: shell, directory: directory,
                                            persistentID: pane.persistentID))
            }
            guard let first = sessions.first else { continue }

            let tab = Tab(session: first)
            tab.sessions = sessions
            tab.customTitle = saved.customTitle
            tab.isPinned = saved.isPinned
            tab.isLocked = saved.isLocked
            tab.aiEnabled = saved.aiEnabled
            // Drop a group reference that no longer exists.
            tab.groupID = saved.groupID.flatMap { knownGroups.contains($0) ? $0 : nil }
            if let rebuilt = PaneNode.rebuild(from: saved.layout, ids: sessions.map(\.id)) {
                tab.root = rebuilt
            }
            tab.focusedSessionID = tab.root.sessionIDs.first ?? first.id
            tabs.append(tab)
        }

        guard !tabs.isEmpty else { return false }
        if let index = snapshot.selectedIndex, tabs.indices.contains(index) {
            selectedTabID = tabs[index].id
        } else {
            selectedTabID = tabs.first?.id
        }
        return true
    }

    // MARK: - Snippets

    func run(_ snippet: Snippet) {
        focusedSession?.send(snippet.keystrokes())
    }

    func saveSnippets() { SettingsStore.shared.update { $0.snippets = snippets } }

    // MARK: - Appearance

    func applyTheme(_ theme: AppTheme) {
        themes.activate(theme)
        for session in allSessions {
            Theme.apply(theme, to: session.terminalView, fontSize: fontSize,
                        fontName: prefs.fontName, opacity: prefs.terminalOpacity,
                        inset: CGFloat(prefs.terminalPadding))
        }
    }

    /// Re-applies the active theme; used after editing it in the theme editor.
    func refreshTheme() {
        for session in allSessions {
            Theme.apply(themes.active, to: session.terminalView, fontSize: fontSize,
                        fontName: prefs.fontName, opacity: prefs.terminalOpacity,
                        inset: CGFloat(prefs.terminalPadding))
        }
    }

    func adjustFontSize(by delta: CGFloat) {
        prefs.fontSize = max(8, min(32, prefs.fontSize + Double(delta)))
    }

    func toggleSidebar() { sidebarVisible.toggle() }
    func toggleInspector() { inspectorVisible.toggle() }

    func jumpToPrompt(previous: Bool) {
        focusedSession?.terminalView.jumpToPrompt(previous: previous)
    }

    func toggleAI(for tab: Tab) {
        tab.aiEnabled.toggle()
        if !tab.aiEnabled {
            tab.activity = .unknown
            tab.suggestedName = nil
            ai.forget(tab: tab.id)
        }
        objectWillChange.send()
        saveLayout()
    }
}

/// Session layout only. Settings live in `SettingsStore`; this is the shape of
/// the workspace, which is state rather than configuration and is not worth
/// backing up to the keychain.
enum Persistence {
    private static var directory: URL { SettingsStore.directory }

    static func loadLayout() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("layout.json"))
        else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    static func saveLayout(_ value: WorkspaceSnapshot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent("layout.json"), options: .atomic)
    }
}
