import SwiftUI
import AppKit

/// Renders one tab's pane tree.
struct PaneView: View {
    @ObservedObject var tab: Tab
    @ObservedObject var workspace: Workspace
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let sessionID):
            if let session = tab.sessions.first(where: { $0.id == sessionID }) {
                TerminalPane(
                    session: session,
                    isFocused: tab.focusedSessionID == sessionID && workspace.selectedTabID == tab.id,
                    showsFocusRing: tab.isSplit && workspace.prefs.showPaneFocusRing,
                    // Unsplit, this pane *is* the terminal panel, so it has
                    // to match the sidebar and inspector or its corners read
                    // as a square slab against the rounded ones either side.
                    cornerRadius: tab.isSplit ? workspace.prefs.cornerRadius
                                              : workspace.prefs.panelCornerRadius,
                    inset: CGFloat(workspace.prefs.terminalPadding)
                )
                .onTapGesture { workspace.focus(session, in: tab) }
            } else {
                Color.clear
            }

        case .split(let splitID, let axis, let children, let fractions):
            SplitContainer(
                tab: tab, workspace: workspace,
                splitID: splitID, axis: axis, children: children, fractions: fractions
            )
        }
    }
}

/// Lays children out along an axis with draggable dividers.
///
/// Fractions rather than absolute sizes: the layout has to survive window
/// resizes, and proportional panes are what every terminal with splits does.
private struct SplitContainer: View {
    @ObservedObject var tab: Tab
    @ObservedObject var workspace: Workspace
    let splitID: UUID
    let axis: SplitAxis
    let children: [PaneNode]
    let fractions: [Double]

    private let dividerThickness: CGFloat = 1
    private let grabWidth: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let dividerSpace = dividerThickness * CGFloat(max(0, children.count - 1))
            let usable = max(0, total - dividerSpace)

            let layout = sizes(usable: usable)

            ZStack(alignment: .topLeading) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    PaneView(tab: tab, workspace: workspace, node: child)
                        .frame(
                            width: axis == .horizontal ? layout.sizes[index] : geo.size.width,
                            height: axis == .horizontal ? geo.size.height : layout.sizes[index]
                        )
                        .offset(
                            x: axis == .horizontal ? layout.offsets[index] : 0,
                            y: axis == .horizontal ? 0 : layout.offsets[index]
                        )
                }

                ForEach(0..<max(0, children.count - 1), id: \.self) { index in
                    divider(at: index, layout: layout, geo: geo, usable: usable)
                }
            }
        }
    }

    private func sizes(usable: CGFloat) -> (sizes: [CGFloat], offsets: [CGFloat]) {
        let normalised = normalisedFractions()
        var sizes: [CGFloat] = []
        var offsets: [CGFloat] = []
        var cursor: CGFloat = 0
        for fraction in normalised {
            let size = usable * CGFloat(fraction)
            sizes.append(size)
            offsets.append(cursor)
            cursor += size + dividerThickness
        }
        return (sizes, offsets)
    }

    /// Guards against drift and against a malformed tree: fractions must sum to
    /// 1 and match the child count, or the layout silently collapses.
    private func normalisedFractions() -> [Double] {
        guard fractions.count == children.count else {
            return Array(repeating: 1.0 / Double(children.count), count: children.count)
        }
        let total = fractions.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 1.0 / Double(children.count), count: children.count)
        }
        return fractions.map { $0 / total }
    }

    private func divider(at index: Int, layout: (sizes: [CGFloat], offsets: [CGFloat]),
                         geo: GeometryProxy, usable: CGFloat) -> some View {
        let position = layout.offsets[index] + layout.sizes[index]

        return Rectangle()
            .fill(workspace.prefs.showPaneDividers
                  ? workspace.themes.active.hairline
                  : Color.clear)
            .frame(
                width: axis == .horizontal ? dividerThickness : geo.size.width,
                height: axis == .horizontal ? geo.size.height : dividerThickness
            )
            .offset(x: axis == .horizontal ? position : 0,
                    y: axis == .horizontal ? 0 : position)
            .overlay(
                // A 1px divider is impossible to grab, so the hit area is wider
                // than the line and carries the resize cursor.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(
                        width: axis == .horizontal ? grabWidth : geo.size.width,
                        height: axis == .horizontal ? geo.size.height : grabWidth
                    )
                    .offset(x: axis == .horizontal ? position - grabWidth / 2 + dividerThickness / 2 : 0,
                            y: axis == .horizontal ? 0 : position - grabWidth / 2 + dividerThickness / 2)
                    .onHover { inside in
                        if inside {
                            axis == .horizontal
                                ? NSCursor.resizeLeftRight.push()
                                : NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(dragGesture(index: index, usable: usable)),
                alignment: .topLeading
            )
    }

    private func dragGesture(index: Int, usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard usable > 0 else { return }
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                var updated = normalisedFractions()

                // Resizing moves space between the two adjacent panes only,
                // leaving the rest of the split untouched.
                let shift = Double(delta / usable)
                let minimum = 0.06
                let pairTotal = updated[index] + updated[index + 1]
                var first = updated[index] + shift
                first = max(minimum, min(pairTotal - minimum, first))
                updated[index] = first
                updated[index + 1] = pairTotal - first

                tab.root = tab.root.updatingFractions(splitID: splitID, to: updated)
            }
    }
}

/// One terminal, kept alive across view rebuilds.
///
/// The `LocalProcessTerminalView` is owned by the session and only reparented
/// here. Letting SwiftUI own it would destroy and rebuild the view — killing
/// the shell and its scrollback.
private struct TerminalPane: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    let isFocused: Bool
    let showsFocusRing: Bool
    let cornerRadius: Double
    let inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let container = PaneContainer()
        container.wantsLayer = true
        // SwiftTerm does not accept file drags, so the container takes them.
        // The terminal view sits on top but is not registered for these types,
        // so AppKit walks up to the container.
        container.registerForDraggedTypes([.fileURL])
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? PaneContainer else { return }
        let terminal = session.terminalView
        // The card behind supplies the colour now; an opaque layer here would
        // paint over the blur and defeat terminal transparency.
        container.layer?.backgroundColor = NSColor.clear.cgColor

        // SwiftUI reuses this container when the pane switches to another
        // session, so the previous session's view has to be evicted. Left in
        // place it stayed stacked underneath, which showed the old tab's
        // output under the new one and — because `layout()` only sizes the
        // first subview — left the visible terminal frozen at its old size.
        if ProcessInfo.processInfo.environment["LILTERM_DEBUG"] != nil {
            FileHandle.standardError.write("PANE update sess=\(session.persistentID.prefix(6)) view=\(UInt(bitPattern: ObjectIdentifier(terminal).hashValue) % 100000) container=\(UInt(bitPattern: ObjectIdentifier(container).hashValue) % 100000) subviews=\(container.subviews.count) focused=\(isFocused)\n".data(using: .utf8)!)
        }
        for stale in container.subviews where stale !== terminal {
            stale.removeFromSuperview()
        }

        if terminal.superview !== container {
            terminal.removeFromSuperview()
            // Manual layout rather than constraints, so a changed inset simply
            // relayouts instead of needing constraints torn down and rebuilt.
            terminal.translatesAutoresizingMaskIntoConstraints = true
            container.addSubview(terminal)
            // AppKit does not mark a view as needing layout just because it
            // gained a subview, so without this the newly attached terminal
            // kept a zero frame: it drew nothing, and with `bounds` at zero
            // `gridSize()` fell back to 80x24 and never reflowed again.
            terminal.frame = container.bounds
            container.needsLayout = true
        }

        container.onDropPaths = { [weak session = session] paths in
            guard let session, !paths.isEmpty else { return }
            // Typed, not executed: dropping a file should hand you the path to
            // use, never run something because a finger slipped.
            session.send(text: paths.map(Self.shellQuote).joined(separator: " ") + " ")
        }

        if container.inset != inset {
            container.inset = inset
            container.needsLayout = true
        }

        // SwiftUI's .clipShape on the content area does not clip an
        // NSViewRepresentable — AppKit draws the terminal outside that mask —
        // so the pane's own layer has to do the rounding, unconditionally.
        container.layer?.cornerRadius = CGFloat(cornerRadius)
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        if showsFocusRing {
            container.layer?.borderWidth = isFocused ? 1 : 0
            container.layer?.borderColor = terminal.cursorColor.withAlphaComponent(0.6).cgColor
        } else {
            container.layer?.borderWidth = 0
        }

        // Focus follows selection; having to click into a pane first is the
        // single most irritating thing a split terminal can do.
        if isFocused {
            DispatchQueue.main.async {
                if container.window?.firstResponder !== terminal {
                    container.window?.makeFirstResponder(terminal)
                }
            }
        }
    }

    /// Wraps a path so spaces and quotes survive the shell.
    static func shellQuote(_ path: String) -> String {
        // A path with no awkward characters is left bare; quoting everything
        // would make the common case ugly for no benefit.
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/=+:,@%")
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Insets the terminal from the card edge so text is not jammed against
    /// the rounded corner, and accepts file drops on the terminal's behalf.
    private final class PaneContainer: NSView {
        var inset: CGFloat = 12
        var onDropPaths: (([String]) -> Void)?

        override var isFlipped: Bool { true }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            paths(from: sender).isEmpty ? [] : .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            paths(from: sender).isEmpty ? [] : .copy
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let dropped = paths(from: sender)
            guard !dropped.isEmpty else { return false }
            onDropPaths?(dropped)
            return true
        }

        private func paths(from sender: NSDraggingInfo) -> [String] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: options) as? [URL] ?? []
            return urls.map(\.path)
        }

        /// Keeps a reparented terminal from sitting at a zero frame until some
        /// unrelated event happens to trigger layout.
        override func didAddSubview(_ subview: NSView) {
            super.didAddSubview(subview)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            // Every subview, not just the first: a container that briefly
            // holds two terminals must not leave one of them unsized.
            // The terminal fills the container; its own `padding` handles the
            // gap between text and edge, so insetting here would double it.
            for terminal in subviews {
                terminal.frame = bounds
            }
        }
    }
}
