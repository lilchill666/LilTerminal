import SwiftUI
import AppKit

/// Theme browser plus editor. Built-ins are read-only and fork on edit, so the
/// shipped presets are always a safe place to return to.
struct ThemeEditor: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var selection: AppTheme
    @State private var status: String?

    init(workspace: Workspace) {
        self.workspace = workspace
        _selection = State(initialValue: workspace.themes.active)
    }

    private var themes: ThemeStore { workspace.themes }

    var body: some View {
        HSplitView {
            themeList
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
            editor
                .frame(minWidth: 420)
        }
        .frame(width: 760, height: 500)
        // Matches SettingsView: panels take the theme's accent rather than
        // whatever colour the system is set to.
        .tint(workspace.themes.active.accentColor)
        .toolbar {
            ToolbarItemGroup {
                Button { importFromFile() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                Button { themes.exportToFile(selection) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var themeList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { selection.id },
                set: { id in if let match = themes.all.first(where: { $0.id == id }) { selection = match } }
            )) {
                Section("Built-in") {
                    ForEach(AppTheme.builtIns) { theme in
                        ThemeSwatchRow(theme: theme, isActive: themes.active.id == theme.id).tag(theme.id)
                    }
                }
                if !themes.custom.isEmpty {
                    Section("Custom") {
                        ForEach(themes.custom) { theme in
                            ThemeSwatchRow(theme: theme, isActive: themes.active.id == theme.id).tag(theme.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 8) {
                Button { selection = themes.makeEditableCopy(of: selection) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.plain)
                .help("Create an editable copy")

                Spacer()

                Button {
                    guard !selection.isBuiltIn else { return }
                    themes.delete(selection)
                    selection = themes.active
                } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .disabled(selection.isBuiltIn)
            }
            .padding(8)
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                preview

                if selection.isBuiltIn {
                    Label("Built-in themes are read-only. Duplicate it to make changes.",
                          systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                coreColors
                ansiGrid
                sharing
            }
            .padding(16)
        }
        .disabled(false)
    }

    private var header: some View {
        HStack {
            if selection.isBuiltIn {
                Text(selection.name).font(.title3.weight(.semibold))
            } else {
                TextField("Name", text: Binding(
                    get: { selection.name },
                    set: { selection.name = $0; commit() }
                ))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
            }

            Spacer()

            Button("Apply") { workspace.applyTheme(selection) }
                .buttonStyle(.borderedProminent)
                .disabled(themes.active.id == selection.id)
        }
    }

    /// Shows the palette against the theme's own background, which is the only
    /// way to judge whether a scheme is actually readable.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("~/projects/api  $ git status")
                .foregroundStyle(HexColor.swiftUI(selection.foreground))
            HStack(spacing: 0) {
                Text("modified: ").foregroundStyle(HexColor.swiftUI(selection.ansi[3]))
                Text("Sources/App.swift").foregroundStyle(HexColor.swiftUI(selection.ansi[4]))
            }
            HStack(spacing: 0) {
                Text("+ added  ").foregroundStyle(HexColor.swiftUI(selection.ansi[2]))
                Text("- removed  ").foregroundStyle(HexColor.swiftUI(selection.ansi[1]))
                Text("note").foregroundStyle(HexColor.swiftUI(selection.ansi[5]))
            }
            Text("selection sample")
                .foregroundStyle(HexColor.swiftUI(selection.foreground))
                .padding(.horizontal, 3)
                .background(HexColor.swiftUI(selection.selection))
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(HexColor.swiftUI(selection.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
    }

    private var coreColors: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Base").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                colorWell("Background", \.background)
                colorWell("Text", \.foreground)
                colorWell("Cursor", \.cursor)
                colorWell("Selection", \.selection)
                colorWell("Accent", \.accent)
            }
            Toggle("Dark theme", isOn: Binding(
                get: { selection.isDark },
                set: { selection.isDark = $0; commit() }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(selection.isBuiltIn)
        }
    }

    private var ansiGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANSI palette").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
            VStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { column in
                            let index = row * 8 + column
                            ansiWell(index: index,
                                     label: (row == 1 ? "bright " : "") + names[column])
                        }
                    }
                }
            }
        }
    }

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    themes.copyToPasteboard(selection)
                    flash("Copied \(selection.name) to clipboard")
                } label: { Label("Copy as JSON", systemImage: "doc.on.doc") }

                Button {
                    if let imported = themes.importFromPasteboard() {
                        selection = imported
                        flash("Imported \(imported.name)")
                    } else {
                        flash("Clipboard does not contain a valid theme")
                    }
                } label: { Label("Paste Theme", systemImage: "clipboard") }
            }

            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            Text("Themes are plain JSON — paste one into chat and it imports on the other side.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Pieces

    private func colorWell(_ label: String, _ path: WritableKeyPath<AppTheme, String>) -> some View {
        VStack(spacing: 4) {
            ColorPicker("", selection: Binding(
                get: { HexColor.swiftUI(selection[keyPath: path]) },
                set: { newValue in
                    selection[keyPath: path] = HexColor.string(from: NSColor(newValue))
                    commit()
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .disabled(selection.isBuiltIn)

            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func ansiWell(index: Int, label: String) -> some View {
        VStack(spacing: 3) {
            ColorPicker("", selection: Binding(
                get: { HexColor.swiftUI(selection.ansi[index]) },
                set: { newValue in
                    selection.ansi[index] = HexColor.string(from: NSColor(newValue))
                    commit()
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .disabled(selection.isBuiltIn)

            Text(label).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(width: 54)
    }

    /// Saves the edit and, if this theme is the live one, repaints every terminal
    /// immediately — editing a theme you cannot see the effect of is useless.
    private func commit() {
        guard !selection.isBuiltIn else { return }
        themes.update(selection)
        if themes.active.id == selection.id { workspace.refreshTheme() }
    }

    private func importFromFile() {
        if let imported = themes.importFromFile() {
            selection = imported
            flash("Imported \(imported.name)")
        } else {
            flash("That file is not a valid theme")
        }
    }

    private func flash(_ message: String) {
        status = message
    }
}

private struct ThemeSwatchRow: View {
    let theme: AppTheme
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            // A miniature of the theme reads faster than its name.
            RoundedRectangle(cornerRadius: 3)
                .fill(HexColor.swiftUI(theme.background))
                .frame(width: 26, height: 16)
                .overlay(
                    HStack(spacing: 1.5) {
                        ForEach([1, 2, 4, 5], id: \.self) { index in
                            Circle().fill(HexColor.swiftUI(theme.ansi[index])).frame(width: 3, height: 3)
                        }
                    }
                )
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.15)))

            Text(theme.name).font(.system(size: 12)).lineLimit(1)

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
            }
        }
    }
}
