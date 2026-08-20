import SwiftUI
import AppKit

enum Toolbar {
    /// Shared content height for every toolbar item, so the system draws all
    /// the pills at one consistent size instead of one per glyph metric.
    static let glyphHeight: CGFloat = 22
}

private extension Image {
    func toolbarGlyph() -> some View {
        self.font(.system(size: 13, weight: .medium))
            .frame(height: Toolbar.glyphHeight)
    }
}

struct RootView: View {
    @ObservedObject var workspace: Workspace
    @State private var showingSnippets = false
    @State private var showingThemes = false
    @State private var showingSettings = false
    @State private var showingFind = false
    @State private var showingPalette = false

    private var prefs: Preferences { workspace.prefs }
    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        ZStack {
            BackgroundLayer(workspace: workspace)

            VStack(spacing: 10) {
                TopBar(workspace: workspace,
                       showingSnippets: $showingSnippets,
                       showingThemes: $showingThemes,
                       showingSettings: $showingSettings)

                HStack(spacing: 0) {
                    if workspace.sidebarVisible {
                        SidebarView(workspace: workspace)
                            .frame(width: CGFloat(prefs.sidebarWidth))
                            .surface(prefs.sidebarBar, slot: .sidebar, theme: theme,
                                     cornerRadius: CGFloat(prefs.panelCornerRadius))
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))

                        SidebarResizer(workspace: workspace)
                    }

                    VStack(spacing: Layout.panelGap) {
                        content

                        // A sibling panel rather than an overlay: over the
                        // terminal card the pill sat on a background it could
                        // not match, because the two surfaces are configured
                        // separately. Beside it, they simply agree.
                        if prefs.showStatusBar {
                            StatusPill(workspace: workspace,
                                       showingSnippets: $showingSnippets,
                                       showingThemes: $showingThemes,
                                       showingSettings: $showingSettings)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                    if workspace.inspectorVisible {
                        InspectorSidebar(workspace: workspace)
                            .frame(width: CGFloat(prefs.inspectorWidth))
                            .surface(prefs.inspectorBar, slot: .inspector, theme: theme,
                                     cornerRadius: CGFloat(prefs.panelCornerRadius))
                            .padding(.leading, 10)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            // Margins are measured from the window edges, not from a system
            // titlebar band, so the top bar sits in a gap it actually controls.
            .padding(Layout.windowMargin)
            .ignoresSafeArea()
        }
        .preferredColorScheme(theme.colorScheme)
        .sheet(isPresented: $showingSnippets) { SnippetsEditor(workspace: workspace) }
        .sheet(isPresented: $showingThemes) { ThemeEditor(workspace: workspace) }
        .sheet(isPresented: $showingSettings) { SettingsView(workspace: workspace) }
        .onReceive(NotificationCenter.default.publisher(for: .openPalette)) { _ in
            withAnimation(workspace.anim(.paneMove)) { showingPalette = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFind)) { _ in
            withAnimation(workspace.anim(.paneMove)) { showingFind = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in showingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .openThemes)) { _ in showingThemes = true }
        .onReceive(NotificationCenter.default.publisher(for: .openSnippets)) { _ in showingSnippets = true }
        .background(SnippetHotkeys(workspace: workspace))
        .background(WindowConfigurator())
        .onAppear {
            if workspace.tabs.isEmpty, !workspace.restoreLayout() {
                workspace.newTab()
            }
        }
        .animation(workspace.anim(.panelMove), value: workspace.sidebarVisible)
        .animation(workspace.anim(.panelMove), value: workspace.inspectorVisible)
        .animation(workspace.anim(.paneMove), value: prefs.showStatusBar)
    }

    private var content: some View {
        Group {
            if let tab = workspace.selectedTab {
                TabCanvas(tab: tab, workspace: workspace)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The pill is inset rather than edge-to-edge, and the panes shrink to
        // make room for it, so it reads as floating over the terminal without
        // ever covering the last line of output.
        .overlay {
            if showingPalette {
                ZStack(alignment: .top) {
                    // A dimming scrim that also dismisses on click.
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { showingPalette = false }
                    CommandPalette(workspace: workspace, isPresented: $showingPalette)
                        .padding(.top, 90)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showingFind {
                FindBar(workspace: workspace, isPresented: $showingFind)
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(terminalBackground)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(prefs.panelCornerRadius), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CGFloat(prefs.panelCornerRadius), style: .continuous)
                .strokeBorder(theme.hairline.opacity(0.7), lineWidth: 0.5)
        }
    }

    /// The terminal card's own surface, independent of the window background.
    ///
    /// Blur here samples what is *behind the window*, so a translucent terminal
    /// shows a frosted desktop rather than a sharp one — which is the effect
    /// people actually mean by a "transparent terminal".
    @ViewBuilder
    private var terminalBackground: some View {
        let tint = HexColor.swiftUI(theme.background).opacity(prefs.terminalOpacity)

        switch prefs.terminalSurface {
        case .solid:
            tint

        case .frosted:
            ZStack {
                // Within-window, not behind-window: the card is clip-shaped, and
                // a behind-window effect view inside a masked layer renders
                // black. It frosts the window's own background layer, which is
                // already the blurred desktop when that mode is on.
                VisualEffect(material: prefs.terminalBlurStrength.material,
                             blending: .withinWindow,
                             cornerRadius: CGFloat(prefs.panelCornerRadius))
                tint
            }

        case .liquidGlass:
            if #available(macOS 26.0, *) {
                ZStack {
                    Rectangle()
                        .fill(.clear)
                        .glassEffect(.regular, in: Rectangle())
                    tint
                }
            } else {
                ZStack {
                    VisualEffect(material: prefs.terminalBlurStrength.material,
                                 blending: .withinWindow,
                                 cornerRadius: CGFloat(prefs.panelCornerRadius))
                    tint
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(theme.textTertiary)
            Text("No tabs open").foregroundStyle(theme.textSecondary)
            Button("New Tab") { workspace.newTab() }
                .keyboardShortcut("t", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The window's own top bar.
///
/// This replaces the system toolbar because AppKit centres toolbar items inside
/// the titlebar band, which puts them at `titlebarHeight / 2` — while the gap a
/// person actually sees runs from the window edge down to the terminal card.
/// Any top margin therefore made the items read as too high, and no amount of
/// padding could fix it from inside a system toolbar.
private struct TopBar: View {
    @ObservedObject var workspace: Workspace
    @Binding var showingSnippets: Bool
    @Binding var showingThemes: Bool
    @Binding var showingSettings: Bool

    /// Clears the traffic lights, which are positioned into this bar by
    /// `WindowConfigurator` using the same shared constants.
    private let trafficLightInset = Layout.barContentInset
    private let barHeight = Layout.topBarHeight

    private var theme: AppTheme { workspace.themes.active }
    private var prefs: Preferences { workspace.prefs }

    var body: some View {
        ZStack {
            // Centred independently of the side groups, so an uneven number of
            // buttons on the left and right cannot pull the title off centre.
            if let tab = workspace.selectedTab {
                BarTitle(tab: tab, workspace: workspace)
            }

            HStack(spacing: 4) {
                BarButton(icon: workspace.sidebarVisible ? "sidebar.leading" : "sidebar.left",
                          help: "Toggle sidebar (⌘B)", theme: theme,
                          animation: workspace.anim(.rowState)) {
                    withAnimation(workspace.anim(.panelMove)) { workspace.toggleSidebar() }
                }

                Spacer(minLength: 12)

                BarButton(icon: "rectangle.split.2x1", help: "Split right (⌘D)",
                          theme: theme, animation: workspace.anim(.rowState),
                          disabled: workspace.selectedTab == nil) {
                    workspace.split(axis: .horizontal)
                }
                BarButton(icon: "rectangle.split.1x2", help: "Split down (⌘⇧D)",
                          theme: theme, animation: workspace.anim(.rowState),
                          disabled: workspace.selectedTab == nil) {
                    workspace.split(axis: .vertical)
                }

                if workspace.selectedTab?.isSplit == true {
                    BarButton(icon: workspace.selectedTab?.isZoomed == true
                              ? "arrow.up.left.and.arrow.down.right"
                              : "arrow.down.right.and.arrow.up.left",
                              help: "Zoom pane (⌘⇧↩)", theme: theme,
                              animation: workspace.anim(.rowState)) {
                        workspace.toggleZoom()
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                BarButton(icon: "sidebar.right",
                          help: "Toggle history & library (⌘⌥I)", theme: theme,
                          animation: workspace.anim(.rowState)) {
                    withAnimation(workspace.anim(.panelMove)) { workspace.toggleInspector() }
                }

                Menu {
                    ForEach(workspace.availableShells) { shell in
                        Button { workspace.newTab(shell: shell) } label: {
                            Label(shell.name, systemImage: "terminal")
                        }
                    }
                    Divider()
                    Button("New Group") { workspace.addGroup() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                } primaryAction: {
                    workspace.newTab()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
                .foregroundStyle(theme.textSecondary)
                .help("New tab (⌘T)")
            }
            .padding(.leading, trafficLightInset)
            .padding(.trailing, 8)
        }
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .surface(prefs.topBar, slot: .top, theme: theme,
                 cornerRadius: CGFloat(prefs.pillCornerRadius))
        .animation(workspace.anim(.paneMove), value: workspace.selectedTab?.isSplit)
    }
}

private struct BarTitle: View {
    @ObservedObject var tab: Tab
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.isSplit ? "rectangle.split.2x1" : "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(workspace.themes.active.textTertiary)

            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(workspace.themes.active.textPrimary)
                .lineLimit(1)

            // The path only earns space when it is not repeating the title.
            if let dir = tab.focused?.workingDirectory, let extra = subtitle(for: dir) {
                Text(extra)
                    .font(.system(size: 11))
                    .foregroundStyle(workspace.themes.active.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .animation(workspace.anim(.rowState), value: tab.displayTitle)
    }

    private func subtitle(for path: String) -> String? {
        let shown = abbreviate(path)
        guard shown != tab.displayTitle,
              (path as NSString).lastPathComponent != tab.displayTitle else { return nil }
        return shown
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct BarButton: View {
    let icon: String
    let help: String
    let theme: AppTheme
    let animation: Animation?
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(hovering && !disabled ? theme.hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(disabled ? theme.textTertiary
                                 : (hovering ? theme.textPrimary : theme.textSecondary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { value in withAnimation(animation) { hovering = value } }
        .help(help)
    }
}

/// Drag handle between the sidebar and the terminal.
///
/// A custom layout loses NavigationSplitView's built-in column resizing, so the
/// grab area is explicit — and wider than it looks, because a hairline is
/// impossible to hit.
private struct SidebarResizer: View {
    @ObservedObject var workspace: Workspace
    @State private var startWidth: Double?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 10)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(workspace.themes.active.textTertiary)
                    .frame(width: 3, height: 34)
                    .opacity(isHovering || startWidth != nil ? 0.8 : 0)
            }
            .onHover { hovering in
                withAnimation(workspace.anim(.rowState)) { isHovering = hovering }
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = startWidth ?? workspace.prefs.sidebarWidth
                        if startWidth == nil { startWidth = base }
                        workspace.prefs.sidebarWidth =
                            min(420, max(170, base + Double(value.translation.width)))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// Renders the selected tab's pane tree.
///
/// This exists to observe the Tab: `tab.root` read from a view that only
/// observes Workspace is captured once and never updates, so splitting a pane
/// would change the model while the screen kept showing the old layout.
private struct TabCanvas: View {
    @ObservedObject var tab: Tab
    @ObservedObject var workspace: Workspace

    /// Zoom hides the other panes, so it needs a visible marker — otherwise a
    /// zoomed tab is indistinguishable from an unsplit one.
    private var zoomBadge: some View {
        Label("Zoomed", systemImage: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(workspace.themes.active.chromeElevated, in: Capsule())
            .overlay(Capsule().stroke(workspace.themes.active.hairline))
            .foregroundStyle(workspace.themes.active.textSecondary)
            .padding(10)
            .transition(.scale.combined(with: .opacity))
    }

    var body: some View {
        PaneView(tab: tab, workspace: workspace, node: tab.visibleRoot)
            .animation(workspace.anim(.paneMove), value: tab.visibleRoot)
            .overlay(alignment: .topTrailing) {
                if tab.isZoomed { zoomBadge }
            }
    }
}

/// Names the tab you are looking at, in place of the hidden window title.
private struct ToolbarTitle: View {
    @ObservedObject var tab: Tab
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.isSplit ? "rectangle.split.2x1" : "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(workspace.themes.active.textTertiary)

            Text(tab.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(workspace.themes.active.textPrimary)
                .lineLimit(1)

            // The path only earns space when it is not just repeating the title.
            if let dir = tab.focused?.workingDirectory, let extra = subtitle(for: dir) {
                Text(extra)
                    .font(.system(size: 11))
                    .foregroundStyle(workspace.themes.active.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: Toolbar.glyphHeight)
        .animation(workspace.anim(.rowState), value: tab.displayTitle)
    }

    private func subtitle(for path: String) -> String? {
        let shown = abbreviate(path)
        guard shown != tab.displayTitle,
              (path as NSString).lastPathComponent != tab.displayTitle else { return nil }
        return shown
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The floating readout at the bottom of the terminal.
private struct StatusPill: View {
    @ObservedObject var workspace: Workspace
    @Binding var showingSnippets: Bool
    @Binding var showingThemes: Bool
    @Binding var showingSettings: Bool

    private var theme: AppTheme { workspace.themes.active }
    private var prefs: Preferences { workspace.prefs }

    var body: some View {
        HStack(spacing: 10) {
            if let tab = workspace.selectedTab {
                StatusMetrics(tab: tab, workspace: workspace)
            }

            Spacer(minLength: 8)

            if prefs.showThemeButton {
                statusButton("Theme", "paintpalette") { showingThemes = true }
            }
            if prefs.showSnippetsButton {
                statusButton("Snippets", "text.badge.plus") { showingSnippets = true }
            }
            statusButton(nil, "slider.horizontal.3") { showingSettings = true }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 12)
        // Now that the bar is its own panel rather than an overlay it can
        // afford real height; at 7 it read as a thin strip stuck to the
        // terminal's edge instead of a sibling of the top bar.
        .padding(.vertical, 10)
        .surface(prefs.statusBarAppearance, slot: .status, theme: theme,
                 cornerRadius: CGFloat(prefs.pillCornerRadius))
        .animation(workspace.anim(.rowState), value: prefs)
    }

    private func statusButton(_ title: String?, _ icon: String,
                              action: @escaping () -> Void) -> some View {
        StatusButton(title: title, icon: icon, theme: theme,
                     animation: workspace.anim(.rowState), action: action)
    }
}

private struct StatusButton: View {
    let title: String?
    let icon: String
    let theme: AppTheme
    let animation: Animation?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if let title { Text(title) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(hovering ? theme.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(animation) { hovering = value } }
        .help(title ?? "Settings")
    }
}

/// Split out so it can observe the Tab directly — Tab's metrics are computed
/// from its sessions, and only a direct observer is told when they change.
private struct StatusMetrics: View {
    @ObservedObject var tab: Tab
    @ObservedObject var workspace: Workspace

    var body: some View {
        let metrics = tab.metrics
        let prefs = workspace.prefs
        let theme = workspace.themes.active

        return HStack(spacing: 10) {
            if prefs.showStatusShell {
                Text(tab.focused?.shell.name ?? "shell")
            }
            if prefs.showStatusMetrics {
                Text(Format.cpu(metrics.cpuPercent))
                    .foregroundStyle(Theme.loadColor(metrics.cpuPercent))
                    .contentTransition(.numericText())
                Text(Format.bytes(metrics.residentBytes))
                    .contentTransition(.numericText())
                Text("\(metrics.processCount) proc").foregroundStyle(theme.textTertiary)
            }
            if tab.isSplit {
                Divider().frame(height: 10)
                Text("\(tab.sessions.count) panes").foregroundStyle(theme.textTertiary)
            }
        }
        .animation(workspace.anim(.rowState), value: metrics)
        .animation(workspace.anim(.paneMove), value: tab.sessions.count)
    }
}

/// Snippet bindings live in an invisible view rather than the main menu so the
/// set can change at runtime without rebuilding the menu bar.
private struct SnippetHotkeys: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        ZStack {
            ForEach(workspace.snippets.filter { $0.key.count == 1 }) { snippet in
                Button("") { workspace.run(snippet) }
                    .keyboardShortcut(
                        KeyEquivalent(Character(snippet.key.lowercased())),
                        modifiers: [.control, .option]
                    )
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

struct SnippetsEditor: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Snippets").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            Text("Sent to the focused pane. Use  {}  to park the cursor — those snippets wait for you instead of running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            List {
                ForEach($workspace.snippets) { $snippet in
                    HStack(spacing: 8) {
                        TextField("Name", text: $snippet.name).frame(width: 120)
                        TextField("Command", text: $snippet.text)
                            .font(.system(size: 11, design: .monospaced))
                        Text("⌃⌥").font(.system(size: 10)).foregroundStyle(.secondary)
                        TextField("key", text: $snippet.key)
                            .frame(width: 28)
                            .multilineTextAlignment(.center)
                        Toggle("Run", isOn: $snippet.runsImmediately)
                            .toggleStyle(.checkbox)
                            .help("Append Return so the command executes")
                        Button {
                            workspace.snippets.removeAll { $0.id == snippet.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button {
                    workspace.snippets.append(Snippet(name: "New", text: "", key: ""))
                } label: { Label("Add", systemImage: "plus") }
                Spacer()
                Button("Restore Defaults") { workspace.snippets = Snippet.starterPack }
            }
            .padding(12)
        }
        .frame(width: 660, height: 420)
        .tint(workspace.themes.active.accentColor)
        .onDisappear { workspace.saveSnippets() }
    }
}
