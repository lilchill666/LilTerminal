import SwiftUI

struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @State private var renamingGroup: UUID?
    @State private var draftName = ""
    /// One namespace so the selection pill physically travels between rows
    /// instead of cross-fading — that motion is what reads as premium.
    @Namespace private var selectionPill
    @FocusState private var filterFocused: Bool

    private var prefs: Preferences { workspace.prefs }
    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        VStack(spacing: 0) {
            if workspace.isFilterVisible { filterField }
            list
        }
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 10))
                .foregroundStyle(theme.textTertiary)
            TextField("Filter tabs", text: $workspace.tabFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(theme.textPrimary)
                .focused($filterFocused)
                .onSubmit { selectFirstMatch() }
            if !workspace.tabFilter.isEmpty {
                Text("\(workspace.ungroupedTabs.count + workspace.groups.reduce(0) { $0 + workspace.tabs(in: $1).count })")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                Button { workspace.tabFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
        .onChange(of: filterFocused) { _, focused in workspace.tabFilterFocused = focused }
        .onExitCommand { workspace.tabFilter = ""; filterFocused = false }
    }

    /// Enter jumps to the single best match, so filtering doubles as a jump.
    private func selectFirstMatch() {
        if let first = workspace.visualOrder.first {
            workspace.select(first)
            workspace.tabFilter = ""
            filterFocused = false
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: prefs.density.rowSpacing) {
                ForEach(workspace.ungroupedTabs) { tab in
                    TabRow(tab: tab, workspace: workspace, pill: selectionPill)
                        .transition(.tabRow)
                }

                ForEach(workspace.groups) { group in
                    GroupSection(group: group, workspace: workspace, pill: selectionPill,
                                 renamingGroup: $renamingGroup, draftName: $draftName)
                }
            }
            .padding(.horizontal, prefs.density.edgeInset)
            .padding(.top, prefs.density.edgeInset + 2)
            .padding(.bottom, prefs.density.edgeInset)
            .animation(workspace.anim(.paneMove), value: workspace.tabs.count)
            .animation(workspace.anim(.disclosure), value: workspace.groups)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if prefs.showSidebarFooter { footer }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTabFilter)) { _ in
            workspace.tabFilterFocused = true
            filterFocused = true
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(workspace.availableShells) { shell in
                    Button { workspace.newTab(shell: shell) } label: {
                        Label(shell.name, systemImage: "terminal")
                    }
                }
                if !workspace.availableShells.contains(where: { $0.name == "fish" }) {
                    Divider()
                    Text("Install fish: brew install fish")
                }
                Divider()
                Button("New Group") { workspace.addGroup() }
            } label: {
                Label("New Tab", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } primaryAction: {
                workspace.newTab()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if prefs.showTabCount {
                Text("\(workspace.tabs.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .contentTransition(.numericText())
                    .animation(workspace.anim(.rowState), value: workspace.tabs.count)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Only a tint and a hairline: an opaque footer would cut a square edge
        // across the bottom of the rounded panel.
        .background(theme.chromeElevated.opacity(0.35))
        .overlay(alignment: .top) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
    }
}

private extension AnyTransition {
    /// Rows drop in from above and shrink out, so adding and closing tabs read
    /// as different events rather than one generic fade.
    static var tabRow: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .center))
        )
    }
}

private struct GroupSection: View {
    let group: TabGroup
    @ObservedObject var workspace: Workspace
    let pill: Namespace.ID
    @Binding var renamingGroup: UUID?
    @Binding var draftName: String
    @State private var isDropTarget = false

    private var prefs: Preferences { workspace.prefs }
    private var theme: AppTheme { workspace.themes.active }
    private var members: [Tab] { workspace.tabs(in: group) }

    var body: some View {
        VStack(alignment: .leading, spacing: prefs.density.rowSpacing) {
            header
            if !group.isCollapsed {
                ForEach(members) { tab in
                    TabRow(tab: tab, workspace: workspace, pill: pill)
                        .padding(.leading, 10)
                        .transition(.tabRow)
                }
                // An empty group is otherwise just a heading over blank space,
                // with no hint that it is a drop target.
                if members.isEmpty {
                    Text("Drop tabs here")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: prefs.cornerRadius, style: .continuous)
                                .strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .padding(.leading, 10)
                        }
                        .transition(.opacity)
                }
            }
        }
        .padding(.top, prefs.density.sectionGap)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.textTertiary)
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .animation(workspace.anim(.disclosure), value: group.isCollapsed)

            if renamingGroup == group.id {
                TextField("Group", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .onSubmit {
                        workspace.rename(group: group, to: draftName)
                        renamingGroup = nil
                    }
            } else {
                Text(group.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            if group.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.textTertiary)
                    .help("Locked: closing tabs in this group asks first")
            }

            if group.isAutoBackground {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.textTertiary)
                    .help("Idle busy tabs are filed here automatically")
            }

            Spacer(minLength: 4)

            // A collapsed group hides its tabs, so surface the aggregate:
            // knowing what a collapsed group costs is the whole point.
            if group.isCollapsed, !members.isEmpty, prefs.showGroupSummary {
                GroupSummary(tabs: members, workspace: workspace)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(workspace.anim(.disclosure)) { workspace.toggleCollapse(group) }
        }
        .dropDestination(for: String.self) { items, _ in
            workspace.acceptDrop(items, before: nil, group: group.id)
        } isTargeted: { targeted in
            withAnimation(workspace.anim(.rowState)) { isDropTarget = targeted }
        }
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.selectionFill)
            }
        }
        .contextMenu {
            Button("Rename") { draftName = group.name; renamingGroup = group.id }
            Button("New Tab in Group") { workspace.newTab(in: group.id) }
            Button(group.isLocked ? "Unlock Group" : "Lock Group") {
                workspace.toggleLock(group: group)
            }
            Divider()
            Button("Ungroup Tabs") {
                // Dissolving a locked group is as destructive as closing it.
                guard !group.isLocked || workspace.confirmDissolve(group) else { return }
                workspace.dissolve(group)
            }
        }
    }
}

private struct GroupSummary: View {
    let tabs: [Tab]
    @ObservedObject var workspace: Workspace

    var body: some View {
        let cpu = tabs.reduce(0.0) { $0 + $1.metrics.cpuPercent }
        let mem = tabs.reduce(UInt64(0)) { $0 + $1.metrics.residentBytes }
        let theme = workspace.themes.active

        HStack(spacing: 4) {
            Text("\(tabs.count)")
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(theme.hoverFill, in: Capsule())
            if workspace.prefs.showCPU {
                Text(Format.cpu(cpu)).foregroundStyle(Theme.loadColor(cpu))
            }
            if workspace.prefs.showMemory {
                Text(Format.bytes(mem)).foregroundStyle(theme.textTertiary)
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(theme.textSecondary)
        .contentTransition(.numericText())
        .animation(workspace.anim(.rowState), value: mem)
    }
}

private struct TabRow: View {
    @ObservedObject var tab: Tab
    @ObservedObject var workspace: Workspace
    let pill: Namespace.ID
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isDropTarget = false

    private var prefs: Preferences { workspace.prefs }
    private var theme: AppTheme { workspace.themes.active }
    private var isSelected: Bool { workspace.selectedTabID == tab.id }

    var body: some View {
        HStack(spacing: 7) {
            if prefs.showStatusDot { statusDot }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(theme.accentColor)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if tab.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(theme.textTertiary)
                            .transition(.scale.combined(with: .opacity))
                    }
                    // The AI label only appears when it says something useful.
                    if let icon = tab.activity.icon, tab.activity != .unknown {
                        Image(systemName: icon)
                            .font(.system(size: 8))
                            .foregroundStyle(tab.activity.demandsAttention
                                             ? theme.accentColor : theme.textTertiary)
                            .help(tab.activity.label)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if isRenaming {
                        TextField("Name", text: $draftTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: prefs.density.titleSize, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .onSubmit { commitRename() }
                            .onExitCommand { isRenaming = false }
                    } else {
                        Text(tab.displayTitle)
                            .font(.system(size: prefs.density.titleSize,
                                          weight: isSelected ? .medium : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(tab.isRunning ? theme.textPrimary : theme.textTertiary)
                    }

                    if tab.isZoomed {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }

                    if tab.isSplit && prefs.showSplitBadge {
                        Text("\(tab.sessions.count)")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 3).padding(.vertical, 0.5)
                            .background(theme.hoverFill, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(theme.textSecondary)
                            .contentTransition(.numericText())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                if prefs.showSubtitle { subtitle }
            }

            Spacer(minLength: 4)

            ZStack(alignment: .trailing) {
                metricsBadge.opacity(isHovering ? 0 : 1)
                closeButton.opacity(isHovering ? 1 : 0)
            }
            .animation(workspace.anim(.rowState), value: isHovering)
        }
        .padding(.horizontal, prefs.density.rowPaddingH)
        .padding(.vertical, prefs.density.rowPaddingV)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { withAnimation(workspace.anim(.paneMove)) { workspace.select(tab) } }
        .onHover { hovering in
            withAnimation(workspace.anim(.rowState)) { isHovering = hovering }
        }
        .draggable(tab.id.uuidString) {
            // A drag with no preview picks up the whole row including its
            // background, which looks broken mid-flight.
            Label(tab.displayTitle, systemImage: "terminal")
                .font(.system(size: 11))
                .padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            workspace.acceptDrop(items, before: tab, group: tab.groupID)
        } isTargeted: { targeted in
            withAnimation(workspace.anim(.rowState)) { isDropTarget = targeted }
        }
        .overlay(alignment: .top) {
            // An insertion line, not a highlight: it has to say *where* the
            // tab lands, not merely that a drop is possible.
            if isDropTarget {
                Capsule()
                    .fill(theme.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: -1)
                    .transition(.opacity)
            }
        }
        .contextMenu { contextMenu }
    }

    private var statusDot: some View {
        Circle()
            .fill(tab.isRunning ? Theme.loadColor(tab.metrics.cpuPercent) : theme.textTertiary)
            .frame(width: 6, height: 6)
            // A busy tab's dot swells slightly: peripheral motion you notice
            // without having to read a number.
            .scaleEffect(tab.metrics.cpuPercent > 50 ? 1.25 : 1)
            .animation(workspace.anim(.easeInOut(duration: 0.5)), value: tab.metrics.cpuPercent > 50)
            .overlay(
                Circle()
                    .stroke(theme.accentColor, lineWidth: tab.hasUnseenOutput ? 1.5 : 0)
                    .frame(width: 11, height: 11)
                    .animation(workspace.anim(.rowState), value: tab.hasUnseenOutput)
            )
    }

    @ViewBuilder private var subtitle: some View {
        if !tab.isRunning {
            Text("exited")
                .font(.system(size: prefs.density.subtitleSize))
                .foregroundStyle(theme.textTertiary)
        } else {
            // When a command is running the title already shows it, so the
            // subtitle carries the location; when idle the location is the
            // title, so the subtitle names the shell instead. Never both.
            let running = tab.metrics.foregroundCommand?.isEmpty == false
            HStack(spacing: 4) {
                // The branch is more useful than the shell name when there is
                // one — it is the thing you need to know before typing into a
                // tab you have not looked at in an hour.
                if prefs.showGitBranch, let git = tab.focused?.git {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: prefs.density.subtitleSize - 1))
                    Text(git.branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if git.isDirty {
                        Circle()
                            .fill(Theme.loadColor(50))
                            .frame(width: 4, height: 4)
                            .help("Uncommitted changes")
                    }
                } else {
                    Text(running ? abbreviate(tab.focused?.workingDirectory ?? "")
                                 : (tab.focused?.shell.name ?? ""))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .font(.system(size: prefs.density.subtitleSize))
            .foregroundStyle(theme.textTertiary)
        }
    }

    @ViewBuilder private var metricsBadge: some View {
        if tab.isRunning, prefs.showCPU || prefs.showMemory {
            let metrics = tab.metrics
            VStack(alignment: .trailing, spacing: 0) {
                if prefs.showCPU {
                    Text(Format.cpu(metrics.cpuPercent))
                        .foregroundStyle(Theme.loadColor(metrics.cpuPercent))
                }
                if prefs.showMemory {
                    Text(Format.bytes(metrics.residentBytes))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .contentTransition(.numericText())
            .animation(workspace.anim(.rowState), value: metrics)
            // Fixed width so changing numbers never make the row twitch.
            .frame(width: 42, alignment: .trailing)
            .help("\(metrics.processCount) processes")
        }
    }

    private var closeButton: some View {
        Button {
            withAnimation(workspace.anim(.paneMove)) { workspace.requestClose(tab) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .padding(3)
                .background(theme.hoverFill, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close tab")
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: prefs.cornerRadius, style: .continuous)
        ZStack {
            if isSelected {
                shape
                    .fill(theme.selectionFill)
                    .overlay(shape.stroke(theme.selectionStroke, lineWidth: 0.5))
                    .matchedGeometryEffect(id: "selection", in: pill)
            } else if isHovering {
                shape.fill(theme.hoverFill)
            }
        }
    }

    private func beginRename() {
        draftTitle = tab.customTitle ?? tab.displayTitle
        isRenaming = true
    }

    private func commitRename() {
        workspace.rename(tab, to: draftTitle)
        isRenaming = false
    }

    @ViewBuilder private var contextMenu: some View {
        Button(tab.isPinned ? "Unpin" : "Pin to Top") {
            withAnimation(workspace.anim(.paneMove)) { workspace.togglePin(tab) }
        }
        Button(tab.isLocked ? "Unlock" : "Lock") { workspace.toggleLock(tab) }
        if workspace.prefs.aiEnabled {
            Button(tab.aiEnabled ? "Exclude from AI" : "Include in AI") {
                workspace.toggleAI(for: tab)
            }
        }
        Divider()
        Button("Rename…") { beginRename() }
        if tab.customTitle != nil {
            Button("Reset Name") { workspace.rename(tab, to: "") }
        }
        Divider()
        Button("Split Right") { workspace.select(tab); workspace.split(axis: .horizontal) }
        Button("Split Down")  { workspace.select(tab); workspace.split(axis: .vertical) }
        if tab.isSplit {
            Button(tab.isZoomed ? "Unzoom Pane" : "Zoom Pane") {
                workspace.select(tab); workspace.toggleZoom()
            }
        }
        Divider()
        Menu("Move to Group") {
            Button("None") { workspace.move(tab, to: nil) }
            Divider()
            ForEach(workspace.groups) { group in
                Button(group.name) { workspace.move(tab, to: group) }
            }
            Divider()
            Button("New Group…") {
                let group = workspace.addGroup(named: "Group")
                workspace.move(tab, to: group)
            }
        }
        Divider()
        Button("Close Tab") { workspace.requestClose(tab) }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
