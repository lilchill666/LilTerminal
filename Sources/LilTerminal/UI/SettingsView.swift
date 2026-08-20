import SwiftUI

/// Every piece of chrome is optional here. The point is that someone can strip
/// the app down to exactly what they use and have it stay that way.
struct SettingsView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .sidebar
    @State private var keychainMessage: String?
    @State private var editingBar: BarSlot = .sidebar

    enum Section: String, CaseIterable, Identifiable {
        case sidebar = "Sidebar"
        case statusBar = "Status Bar"
        case background = "Background"
        case ai = "AI"
        case feel = "Feel"
        case terminal = "Terminal"
        case storage = "Storage"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .sidebar:    return "sidebar.left"
            case .statusBar:  return "menubar.rectangle"
            case .background: return "photo"
            case .ai:         return "sparkles"
            case .feel:       return "wand.and.stars"
            case .terminal:   return "terminal"
            case .storage:    return "externaldrive"
            }
        }
    }

    private var prefs: Binding<Preferences> { $workspace.prefs }
    private var current: Preferences { workspace.prefs }
    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            // Form/.grouped gives the native Settings look: labels on the left,
            // controls aligned in a column on the right. Hand-rolled HStacks
            // produced a ragged edge that read as unfinished.
            Form {
                switch section {
                case .sidebar:    sidebarSection
                case .statusBar:  statusBarSection
                case .background: backgroundSection
                case .ai:         AISettingsSection(workspace: workspace, ai: workspace.ai, prefs: prefs)
                case .feel:       feelSection
                case .terminal:   terminalSection
                case .storage:    storageSection
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Reset to Defaults") {
                    withAnimation { workspace.prefs = Preferences() }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        // Controls pick up the theme's accent instead of the system one, so the
        // panel belongs to the app rather than to whatever colour macOS is set to.
        .tint(theme.accentColor)
    }

    // MARK: - Sidebar

    @ViewBuilder private var sidebarSection: some View {
        SwiftUI.Section("Show in each tab row") {
            Toggle("Status dot", isOn: prefs.showStatusDot)
            Toggle("CPU usage", isOn: prefs.showCPU)
            Toggle("Memory usage", isOn: prefs.showMemory)
            Toggle("Subtitle (path or shell)", isOn: prefs.showSubtitle)
            Toggle("Split-pane count badge", isOn: prefs.showSplitBadge)
            Toggle("Git branch", isOn: prefs.showGitBranch)
        }

        SwiftUI.Section("Sidebar chrome") {
            Toggle("Group totals when collapsed", isOn: prefs.showGroupSummary)
            Toggle("Bottom bar with New Tab", isOn: prefs.showSidebarFooter)
            Toggle("Tab count", isOn: prefs.showTabCount)
            Toggle("Filter box when many tabs", isOn: prefs.showTabFilter)
                .disabled(!current.showSidebarFooter)
            LabeledContent("Width") {
                slider(prefs.sidebarWidth, 170...420, 2, "\(Int(current.sidebarWidth)) pt")
            }
        }
    }

    // MARK: - Status bar

    @ViewBuilder private var statusBarSection: some View {
        SwiftUI.Section {
            Toggle("Show status bar", isOn: prefs.showStatusBar)
        } footer: {
            Text("Hidden buttons stay reachable from the menu bar and their keyboard shortcuts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SwiftUI.Section("Contents") {
            Toggle("Shell name", isOn: prefs.showStatusShell)
            Toggle("CPU, memory, process count", isOn: prefs.showStatusMetrics)
            Toggle("Theme button", isOn: prefs.showThemeButton)
            Toggle("Snippets button", isOn: prefs.showSnippetsButton)
        }
        .disabled(!current.showStatusBar)
    }

    // MARK: - Background

    @ViewBuilder private var backgroundSection: some View {
        SwiftUI.Section {
            Picker("Behind the terminal", selection: prefs.backgroundMode) {
                ForEach(BackgroundMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(current.backgroundMode.help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if current.backgroundMode == .image {
            SwiftUI.Section("Image") {
                LabeledContent("File") {
                    HStack(spacing: 8) {
                        Button("Choose…") { workspace.chooseBackgroundImage() }
                        if current.backgroundImagePath != nil {
                            Button("Remove") { workspace.clearBackgroundImage() }
                        }
                    }
                }
                if let path = current.backgroundImagePath {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                LabeledContent("Opacity") {
                    slider(prefs.backgroundImageOpacity, 0.05...1, 0.05,
                           percent(current.backgroundImageOpacity))
                }
                LabeledContent("Blur") {
                    slider(prefs.backgroundImageBlur, 0...40, 1,
                           String(format: "%.0f", current.backgroundImageBlur))
                }
            }
        }

        if current.backgroundMode == .blur {
            SwiftUI.Section {
                Picker("Strength", selection: prefs.blurStrength) {
                    ForEach(BlurStrength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Desktop blur")
            } footer: {
                Text("macOS blur materials are fixed recipes, so this picks a recipe rather than a radius.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if current.backgroundMode != .solid {
            SwiftUI.Section {
                LabeledContent("Tint") {
                    slider(prefs.backgroundTint, 0...0.95, 0.05, percent(current.backgroundTint))
                }
            } header: {
                Text("Readability")
            } footer: {
                Text("Theme colour laid over the background. Raise it if text is hard to read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        SwiftUI.Section {
            LabeledContent("Opacity") {
                slider(prefs.terminalOpacity, 0.15...1, 0.05, percent(current.terminalOpacity))
            }
        } header: {
            Text("Terminal field")
        } footer: {
            Text("Affects the margin around the text. The text area itself stays opaque — the terminal engine does not currently composite a translucent background in this embedding.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Feel

    @ViewBuilder private var feelSection: some View {
        SwiftUI.Section("Density") {
            Picker("", selection: prefs.density) {
                ForEach(Density.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        SwiftUI.Section("Motion") {
            Toggle("Animations", isOn: prefs.animationsEnabled)
            LabeledContent("Speed") {
                slider(prefs.animationSpeed, 0.5...2.0, 0.1,
                       String(format: "%.1f×", current.animationSpeed))
            }
            .disabled(!current.animationsEnabled)
        }

        SwiftUI.Section {
            Picker("", selection: $editingBar) {
                ForEach(BarSlot.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            barEditor(for: editingBar)
        } header: {
            Text("Bars")
        } footer: {
            Text("Each bar is painted separately, so the terminal can be exactly as translucent as you want it without the chrome following along.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SwiftUI.Section("Shape") {
            LabeledContent("Rows") {
                slider(prefs.cornerRadius, 0...14, 1, "\(Int(current.cornerRadius))")
            }
            LabeledContent("Panels") {
                slider(prefs.panelCornerRadius, 0...24, 1, "\(Int(current.panelCornerRadius))")
            }
            LabeledContent("Status pill") {
                slider(prefs.pillCornerRadius, 0...20, 1, "\(Int(current.pillCornerRadius))")
            }
            Toggle("Focus ring on active pane", isOn: prefs.showPaneFocusRing)
            Toggle("Pane dividers", isOn: prefs.showPaneDividers)
        }
    }

    // MARK: - Terminal

    @ViewBuilder private var terminalSection: some View {
        SwiftUI.Section("Font") {
            Picker("Family", selection: prefs.fontName) {
                ForEach(Theme.availableMonoFonts(), id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Size") {
                slider(prefs.fontSize, 9...24, 1, "\(Int(current.fontSize)) pt")
            }
            LabeledContent("Text inset") {
                slider(prefs.terminalPadding, 0...28, 1, "\(Int(current.terminalPadding)) pt")
            }
        }

        SwiftUI.Section {
            Toggle("Confirm risky pastes", isOn: prefs.pasteGuardEnabled)
            Toggle("Warn on destructive commands", isOn: prefs.pasteGuardRiskyCommands)
                .disabled(!current.pasteGuardEnabled)
            LabeledContent("Confirm from") {
                HStack(spacing: 8) {
                    Stepper(value: prefs.pasteGuardLineThreshold, in: 1...20) {
                        Text("\(current.pasteGuardLineThreshold) lines")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .disabled(!current.pasteGuardEnabled)
        } header: {
            Text("Paste guard")
        } footer: {
            Text("A paste ending in a newline runs the moment it lands. This shows you what is about to run first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SwiftUI.Section {
            Toggle("Reopen tabs on launch", isOn: prefs.restoreSessions)
            Toggle("Keep shells running after quit", isOn: prefs.persistentSessions)
            Toggle("Auto-file idle background jobs", isOn: $workspace.autoFileBackgroundJobs)
        } header: {
            Text("Behaviour")
        } footer: {
            Text("Reopening restores tabs, groups, splits, and directories. Keeping shells running hands them to a small helper that outlives the app, so a quit or a crash does not kill a long job — and relaunching reattaches to the same processes, scrollback included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SwiftUI.Section("Shells found") {
            ForEach(workspace.availableShells) { shell in
                LabeledContent(shell.name) {
                    Text(shell.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            if !workspace.availableShells.contains(where: { $0.name == "fish" }) {
                Text("fish is not installed — `brew install fish` and it appears here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bar editor

    @ViewBuilder private func barEditor(for slot: BarSlot) -> some View {
        let binding = Binding<BarAppearance>(
            get: { current[bar: slot] },
            set: { prefs.wrappedValue[bar: slot] = $0 }
        )

        Picker("Style", selection: binding.style) {
            ForEach(SurfaceStyle.allCases.filter(\.isAvailable)) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)

        if binding.wrappedValue.style == .frosted {
            Picker("Blur", selection: binding.blurStrength) {
                ForEach(BlurStrength.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            LabeledContent("Tint") {
                slider(binding.opacity, 0...1, 0.05, percent(binding.wrappedValue.opacity))
            }

            Toggle("Blur the desktop, not the window", isOn: binding.blurBehindWindow)
        }

        LabeledContent("Shadow") {
            slider(binding.shadow, 0...0.5, 0.02,
                   binding.wrappedValue.shadow <= 0.001 ? "none"
                       : percent(binding.wrappedValue.shadow))
        }

        Toggle("Keep blur when unfocused", isOn: binding.stayActiveWhenUnfocused)

        if binding.wrappedValue.style == .frosted,
           current.backgroundMode == .blur,
           !binding.wrappedValue.blurBehindWindow {
            // The exact combination that comes out flat and dark.
            Label("With a blurred background, a bar that blurs the window instead of the desktop renders flat. Turn on “Blur the desktop” above.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Storage

    @ViewBuilder private var storageSection: some View {
        let store = SettingsStore.shared

        SwiftUI.Section {
            LabeledContent("Settings file") {
                Button("Reveal in Finder") { store.revealInFinder() }
            }
            Text(SettingsStore.fileURL.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            LabeledContent("Loaded from") {
                Text(store.origin).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Where settings live")
        } footer: {
            Text("A plain JSON file, not the defaults database. Dragging the app to the Trash leaves this folder alone; a cleaner utility does not.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SwiftUI.Section {
            Toggle("Keep a copy in the keychain", isOn: prefs.keychainBackup)
            LabeledContent("Backup") {
                HStack(spacing: 8) {
                    Button("Back up now") {
                        keychainMessage = store.backupToKeychainNow()
                            ? "Backed up." : "Could not write to the keychain."
                    }
                    Button("Restore") {
                        keychainMessage = store.restoreFromKeychain()
                            ? "Restored — relaunch to apply." : "No usable backup found."
                    }
                    .disabled(!Keychain.hasBackup)
                }
            }
            if let keychainMessage {
                Text(keychainMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Keychain backup")
        } footer: {
            Text("The keychain survives deleting the app and its support folder, so a reinstall can recover from it. Because this app is signed ad-hoc, macOS may ask permission the first time a rebuilt copy reads the item.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SwiftUI.Section {
            LabeledContent("Settings file") {
                HStack(spacing: 8) {
                    Button("Export…") { store.exportToFile() }
                    Button("Import…") {
                        keychainMessage = store.importFromFile()
                            ? "Imported — relaunch to apply." : "That file is not a settings export."
                    }
                }
            }
        } header: {
            Text("Move to another Mac")
        } footer: {
            Text("Exports everything on this screen — preferences, themes, snippets and groups — as one file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pieces

    private func slider(_ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ step: Double, _ readout: String) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: range, step: step)
            Text(readout)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .frame(minWidth: 240)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
