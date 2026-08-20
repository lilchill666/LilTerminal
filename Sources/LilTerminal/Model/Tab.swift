import Foundation
import SwiftUI

/// One entry in the sidebar. Holds one or more sessions arranged in a pane tree.
@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()

    @Published var root: PaneNode
    @Published var sessions: [TerminalSession]
    @Published var focusedSessionID: UUID
    @Published var groupID: UUID?
    @Published var customTitle: String?
    @Published var hasUnseenOutput = false
    /// The most recent long command that finished while you were away.
    @Published var finishedCommand: HistoryEntry?
    /// Per-tab opt-out. Some sessions hold things you would rather no model
    /// ever read, even a local one.
    @Published var aiEnabled = true
    @Published var activity: TabActivity = .unknown
    /// Set by auto-naming; a user-set name always wins.
    @Published var suggestedName: String?
    /// When set, only this pane renders — a temporary full-screen for one pane
    /// of a busy split, without disturbing the layout you return to.
    @Published var zoomedSessionID: UUID?
    /// Pinned tabs sort to the top and stay put.
    @Published var isPinned = false
    /// Locked tabs refuse to close without confirmation.
    @Published var isLocked = false

    init(session: TerminalSession) {
        self.root = .leaf(session.id)
        self.sessions = [session]
        self.focusedSessionID = session.id
    }

    var focused: TerminalSession? {
        sessions.first { $0.id == focusedSessionID }
    }

    var isSplit: Bool { sessions.count > 1 }
    var isZoomed: Bool { zoomedSessionID != nil }

    /// The tree to render: the zoomed pane alone, or the whole layout.
    var visibleRoot: PaneNode {
        if let zoomedSessionID, sessions.contains(where: { $0.id == zoomedSessionID }) {
            return .leaf(zoomedSessionID)
        }
        return root
    }

    func toggleZoom() {
        // Zooming a tab that is not split would do nothing visible but would
        // leave a confusing "zoomed" state behind.
        guard isSplit else { zoomedSessionID = nil; return }
        zoomedSessionID = zoomedSessionID == nil ? focusedSessionID : nil
    }

    /// Metrics for the tab are the sum across its panes: the sidebar number
    /// should describe the whole tab, not whichever pane happens to be focused.
    var metrics: SessionMetrics {
        var total = SessionMetrics()
        for session in sessions where session.isRunning {
            total.cpuPercent += session.metrics.cpuPercent
            total.residentBytes += session.metrics.residentBytes
            total.processCount += session.metrics.processCount
        }
        total.foregroundCommand = focused?.metrics.foregroundCommand
            ?? sessions.compactMap(\.metrics.foregroundCommand).first
        return total
    }

    var isRunning: Bool { sessions.contains(where: \.isRunning) }

    var displayTitle: String {
        if let customTitle { return customTitle }
        if let suggestedName, !suggestedName.isEmpty { return suggestedName }
        if let focused {
            if let command = focused.metrics.foregroundCommand, !command.isEmpty { return command }
            if let dir = focused.workingDirectory {
                // The home folder's basename is the user's name, which is a
                // useless tab title; every shell calls it ~ instead.
                if dir == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
                return (dir as NSString).lastPathComponent
            }
            return focused.shell.name
        }
        return "Tab"
    }

    /// Idle but still working: the case where a tab is cluttering the list.
    var looksLikeBackgroundJob: Bool {
        sessions.contains { $0.looksLikeBackgroundJob }
    }

    func add(_ session: TerminalSession, splitting target: UUID, axis: SplitAxis) {
        // Splitting while zoomed would hide the pane just created.
        zoomedSessionID = nil
        root = root.splitting(target, with: session.id, axis: axis)
        sessions.append(session)
        focusedSessionID = session.id
    }

    /// Returns false when the tab is now empty and the caller should close it.
    func remove(_ sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return true }
        session.terminate()
        sessions.removeAll { $0.id == sessionID }

        if zoomedSessionID == sessionID { zoomedSessionID = nil }
        guard let newRoot = root.removing(sessionID) else { return false }
        root = newRoot

        if focusedSessionID == sessionID {
            focusedSessionID = newRoot.sessionIDs.first ?? sessionID
        }
        return true
    }

    /// Cycles focus through panes in tree order — the order they appear on screen.
    func focusNextPane(_ offset: Int) {
        let order = root.sessionIDs
        guard order.count > 1, let current = order.firstIndex(of: focusedSessionID) else { return }
        let next = ((current + offset) % order.count + order.count) % order.count
        focusedSessionID = order[next]
    }

    func terminateAll() {
        for session in sessions { session.terminate() }
    }
}
