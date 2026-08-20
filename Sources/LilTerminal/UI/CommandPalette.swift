import SwiftUI

/// One thing the palette can do.
struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let group: String
    let action: () -> Void
}

/// Fuzzy launcher for tabs, snippets, themes and commands.
///
/// Once there are more tabs than fit comfortably in the sidebar, scanning is
/// slower than typing. This is the escape hatch for that.
struct CommandPalette: View {
    @ObservedObject var workspace: Workspace
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textTertiary)
                TextField("Jump to a tab, run a snippet, switch theme…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                    .focused($focused)
                    .onSubmit { runSelection() }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.4)

            let items = matches
            if items.isEmpty {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index, count: items.count)
                                    .id(index)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selection) { _, new in
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 520)
        .surface(workspace.prefs.statusBarAppearance, slot: .status, theme: theme,
                 cornerRadius: 14)
        .onAppear { focused = true }
        .onExitCommand { isPresented = false }
        // Arrow keys move the selection; the text field would otherwise eat them.
        .background(KeyCatcher(
            onUp: { selection = max(0, selection - 1) },
            onDown: { selection = min(matches.count - 1, selection + 1) }
        ))
    }

    private func row(_ item: PaletteItem, index: Int, count: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.icon)
                .font(.system(size: 11))
                .foregroundStyle(index == selection ? theme.accentColor : theme.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text(item.group)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.hoverFill, in: Capsule())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(index == selection ? theme.selectionFill : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = index; runSelection() }
    }

    private func runSelection() {
        let items = matches
        guard items.indices.contains(selection) else { return }
        isPresented = false
        items[selection].action()
    }

    // MARK: - Items

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []

        for tab in workspace.visualOrder {
            let group = workspace.groups.first { $0.id == tab.groupID }?.name
            items.append(PaletteItem(
                title: tab.displayTitle,
                subtitle: [group, tab.focused?.workingDirectory].compactMap { $0 }.joined(separator: "  ·  "),
                icon: tab.isSplit ? "rectangle.split.2x1" : "terminal",
                group: "Tab") { workspace.select(tab) })
        }

        for snippet in workspace.snippets {
            items.append(PaletteItem(
                title: snippet.name, subtitle: snippet.text,
                icon: snippet.isPrompt ? "text.bubble" : "chevron.right.square",
                group: snippet.folder.isEmpty ? "Snippet" : snippet.folder) { workspace.run(snippet) })
        }

        // Recent history from the focused tab, most recent first.
        if let session = workspace.focusedSession {
            for entry in session.history.filtered("").prefix(30) {
                items.append(PaletteItem(
                    title: entry.command, subtitle: entry.directory,
                    icon: "clock.arrow.circlepath", group: "History") {
                        workspace.focusedSession?.send(text: entry.command)
                    })
            }
        }

        for theme in workspace.themes.all {
            items.append(PaletteItem(
                title: theme.name, subtitle: nil, icon: "paintpalette",
                group: "Theme") { workspace.applyTheme(theme) })
        }

        items.append(PaletteItem(title: "New Tab", subtitle: nil, icon: "plus",
                                 group: "Action") { workspace.newTab() })
        items.append(PaletteItem(title: "Split Right", subtitle: nil,
                                 icon: "rectangle.split.2x1",
                                 group: "Action") { workspace.split(axis: .horizontal) })
        items.append(PaletteItem(title: "Split Down", subtitle: nil,
                                 icon: "rectangle.split.1x2",
                                 group: "Action") { workspace.split(axis: .vertical) })
        items.append(PaletteItem(title: "Toggle History & Library", subtitle: nil,
                                 icon: "sidebar.right",
                                 group: "Action") { workspace.toggleInspector() })
        return items
    }

    private var matches: [PaletteItem] {
        guard !query.isEmpty else { return allItems }
        return allItems
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = Self.score(item.title, query: query)
                        ?? Self.score(item.subtitle ?? "", query: query).map({ $0 + 40 })
                else { return nil }
                return (item, score)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Subsequence match, scored so tighter and earlier matches rank first.
    /// Lower is better; nil means no match.
    static func score(_ candidate: String, query: String) -> Int? {
        let haystack = Array(candidate.lowercased())
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }

        var index = 0
        var first: Int?
        var last = 0
        for (position, character) in haystack.enumerated() where index < needle.count {
            if character == needle[index] {
                if first == nil { first = position }
                last = position
                index += 1
            }
        }
        guard index == needle.count, let start = first else { return nil }
        // Span penalises scattered matches; start penalises late ones.
        return (last - start) * 2 + start
    }
}

/// Routes arrow keys to the palette instead of the focused text field.
private struct KeyCatcher: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(onUp: onUp, onDown: onDown)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.install(onUp: onUp, onDown: onDown)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var up: (() -> Void)?
        private var down: (() -> Void)?

        func install(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
            up = onUp
            down = onDown
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 126: self?.up?(); return nil
                case 125: self?.down?(); return nil
                default:  return event
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
