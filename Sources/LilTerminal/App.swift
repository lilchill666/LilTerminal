import SwiftUI
import AppKit

@main
struct LilTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        Window("LilTerminal", id: "main") {
            RootView(workspace: workspace)
                .frame(minWidth: 720, minHeight: 420)
        }
        // The app draws its own top bar, so the system titlebar must get out of
        // the way entirely — otherwise it paints opaquely over that bar.
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(workspace: workspace) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The last line of defence for locked work: a quit is far easier to
    /// trigger by accident than any individual close.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let workspace = Workspace.current, workspace.hasLockedWork else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Quit LilTerminal?"
            alert.informativeText = workspace.appIsLocked
                ? "The app is locked. Quitting will end everything running in it."
                : "Some tabs or groups are locked. Quitting will end everything running in them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The debounced write may still be pending.
        MainActor.assumeIsolated { SettingsStore.shared.writeNow() }
        // With persistence on, quitting must not take the shells with it.
        MainActor.assumeIsolated {
            if Workspace.current?.prefs.persistentSessions == true {
                Workspace.current?.detachAll()
            }
        }
        // Directories drift as the user cds around; the layout on disk is only
        // current if it is rewritten at the last possible moment.
        MainActor.assumeIsolated { Workspace.current?.saveLayout() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Verifies the vendored Ghostty engine links and parses inside the real
        // app bundle, not just in a test harness. Off unless asked for.
        if ProcessInfo.processInfo.environment["LILTERM_ENGINE_TEST"] != nil {
            let result = GhosttyCore.selfTest() ?? "<nil>"
            FileHandle.standardError.write("ghostty-vt self-test: \(result)\n".data(using: .utf8)!)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.requestAuthorizationIfNeeded()

        if ProcessInfo.processInfo.environment["LILTERM_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Self.probeKeyEncoding() }
        }
    }
}

extension AppDelegate {
    /// Encodes synthetic key events to see what the encoder actually produces,
    /// without typing into anyone's session.
    static func probeKeyEncoding() {
        guard let encoder = KeyEncoder() else {
            FileHandle.standardError.write("key probe: encoder init failed\n".data(using: .utf8)!)
            return
        }
        MainActor.assumeIsolated {
            encoder.sync(with: Workspace.current?.focusedSession?.terminalView.terminalHandle)
        }

        let cases: [(String, String, String, UInt16, NSEvent.ModifierFlags)] = [
            ("letter a", "a", "a", 0, []),
            ("shift A", "A", "a", 0, [.shift]),
            ("digit 1", "1", "1", 18, []),
            ("return", "\r", "\r", 36, []),
            ("tab", "\t", "\t", 48, []),
            ("ctrl-c", "\u{3}", "c", 8, [.control]),
            ("ctrl-d", "\u{4}", "d", 2, [.control]),
            ("arrow up", "\u{F700}", "\u{F700}", 126, []),
            ("backspace", "\u{8}", "\u{8}", 51, []),
        ]
        for (label, characters, unshifted, keyCode, flags) in cases {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: unshifted,
                isARepeat: false, keyCode: keyCode) else { continue }
            let bytes = encoder.encode(event)
            let description = bytes.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil"
            FileHandle.standardError.write("key probe [\(label)] -> \(description)\n".data(using: .utf8)!)
        }
    }
}

extension Notification.Name {
    // The panels live in RootView's state; menu commands are outside that view,
    // so they ask for a panel rather than reaching into it.
    static let openSettings = Notification.Name("openSettings")
    static let openThemes = Notification.Name("openThemes")
    static let openSnippets = Notification.Name("openSnippets")
    static let openFind = Notification.Name("openFind")
    static let openPalette = Notification.Name("openPalette")
    static let focusTabFilter = Notification.Name("focusTabFilter")
}

struct AppCommands: Commands {
    @ObservedObject var workspace: Workspace

    var body: some Commands {
        // Replacing the stock New Item group keeps ⌘T where people expect it.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") { workspace.newTab() }
                .keyboardShortcut("t", modifiers: .command)

            Menu("New Tab with Shell") {
                ForEach(Array(workspace.availableShells.enumerated()), id: \.element.id) { index, shell in
                    Button(shell.name) { workspace.newTab(shell: shell) }
                        // ⌘⌥1 is the login shell, ⌘⌥2 the next (fish, once installed).
                        .keyboardShortcut(
                            index < 9 ? KeyEquivalent(Character("\(index + 1)")) : .init(" "),
                            modifiers: [.command, .option]
                        )
                }
            }

            Divider()

            Button("New Group") { workspace.addGroup() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // Replaces the stock Find group, which targets NSTextView and does
        // nothing for a terminal view.
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { workspace.find(.showFindPanel) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { workspace.find(.next) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { workspace.find(.previous) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { workspace.find(.setFindString) }
                .keyboardShortcut("e", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { workspace.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Pane") { workspace.closeFocusedPane() }
                .keyboardShortcut("w", modifiers: [.command, .shift])

            Divider()

            Button(workspace.selectedTab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                if let tab = workspace.selectedTab { workspace.togglePin(tab) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(workspace.selectedTab == nil)

            Button(workspace.selectedTab?.isLocked == true ? "Unlock Tab" : "Lock Tab") {
                if let tab = workspace.selectedTab { workspace.toggleLock(tab) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(workspace.selectedTab == nil)

            Toggle("Lock App", isOn: $workspace.appIsLocked)
        }

        CommandGroup(after: .sidebar) {
            Button(workspace.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                workspace.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)

            Button(workspace.inspectorVisible ? "Hide History & Library" : "Show History & Library") {
                workspace.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Button("Filter Tabs…") {
                NotificationCenter.default.post(name: .focusTabFilter, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button("Command Palette…") {
                NotificationCenter.default.post(name: .openPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("Bigger Text") { workspace.adjustFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { workspace.adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") {
                workspace.adjustFontSize(by: Theme.defaultFontSize - workspace.fontSize)
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Menu("Theme") {
                ForEach(workspace.themes.all) { theme in
                    Button(theme.name) { workspace.applyTheme(theme) }
                }
                Divider()
                Button("Edit Themes…") {
                    NotificationCenter.default.post(name: .openThemes, object: nil)
                }
            }

            Divider()

            Menu("Background") {
                Picker("Background", selection: $workspace.prefs.backgroundMode) {
                    ForEach(BackgroundMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Menu("Panel Style") {
                Picker("Panel Style", selection: $workspace.prefs.surfaceStyle) {
                    ForEach(SurfaceStyle.allCases.filter(\.isAvailable)) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            Toggle("Animations", isOn: $workspace.prefs.animationsEnabled)
            Toggle("Status Bar", isOn: $workspace.prefs.showStatusBar)

            Divider()
        }

        CommandMenu("Panes") {
            Button("Split Right") { workspace.split(axis: .horizontal) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { workspace.split(axis: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Previous Prompt") { workspace.jumpToPrompt(previous: true) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Prompt") { workspace.jumpToPrompt(previous: false) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button("Next Pane") { workspace.focusPane(1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Pane") { workspace.focusPane(-1) }
                .keyboardShortcut("[", modifiers: [.command, .option])

            Divider()

            Button("Zoom Pane") { workspace.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
        }

        CommandMenu("Tabs") {
            Button("Next Tab") { workspace.cycleSelection(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { workspace.cycleSelection(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            // ⌘1…⌘9 jump straight to a tab, matching the sidebar's visible order.
            ForEach(0..<9, id: \.self) { index in
                Button("Tab \(index + 1)") { workspace.selectIndex(index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }

            Divider()

            Toggle("Auto-file Background Jobs", isOn: $workspace.autoFileBackgroundJobs)
        }

        CommandMenu("Snippets") {
            ForEach(workspace.snippets) { snippet in
                Button(snippet.name) { workspace.run(snippet) }
            }
            Divider()
            Button("Edit Snippets…") {
                NotificationCenter.default.post(name: .openSnippets, object: nil)
            }
        }
    }
}
