import SwiftUI

/// The right-hand inspector: what this tab has run, and what you can send it.
struct InspectorSidebar: View {
    @ObservedObject var workspace: Workspace
    @State private var tab: Panel = .history
    @State private var query = ""
    @State private var semanticResults: [HistoryEntry]?
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    enum Panel: String, CaseIterable, Identifiable {
        case history = "History"
        case library = "Library"
        var id: String { rawValue }
    }

    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
                TextField(tab == .history ? "Filter history" : "Search library", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textPrimary)
                if searching {
                    ProgressView().controlSize(.mini)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        semanticResults = nil
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider().opacity(0.4)

            switch tab {
            case .history: historyList
            case .library: libraryList
            }
        }
        // Semantic search is one call per settled query, never per keystroke.
        .onChange(of: query) { _, new in
            searchTask?.cancel()
            guard tab == .history, workspace.prefs.aiEnabled,
                  workspace.prefs.aiSearchEnabled, new.count >= 3,
                  // Only worth asking a model when substring search found little.
                  (workspace.focusedSession?.history.filtered(new).count ?? 0) < 3
            else {
                semanticResults = nil
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let history = workspace.focusedSession?.history else { return }
                await MainActor.run { searching = true }
                let matches = await workspace.ai.searchHistory(query: new, in: history)
                await MainActor.run {
                    searching = false
                    guard !Task.isCancelled else { return }
                    semanticResults = matches
                }
            }
        }
        .onDisappear { searchTask?.cancel() }
        .background(theme.chrome.opacity(0.4))
        .tint(theme.accentColor)
    }

    // MARK: - History

    @ViewBuilder private var historyList: some View {
        if let session = workspace.focusedSession {
            HistoryList(history: session.history, workspace: workspace,
                        query: query, semanticResults: semanticResults)
        } else {
            emptyState("No tab selected")
        }
    }

    // MARK: - Library

    private var libraryList: some View {
        let matches = workspace.snippets.filter {
            query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.text.localizedCaseInsensitiveContains(query)
        }
        let folders = Dictionary(grouping: matches) { $0.folder.isEmpty ? "Other" : $0.folder }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(folders.keys.sorted(), id: \.self) { folder in
                    Text(folder.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                    ForEach(folders[folder] ?? []) { snippet in
                        LibraryRow(snippet: snippet, workspace: workspace)
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                NotificationCenter.default.post(name: .openSnippets, object: nil)
            } label: {
                Label("Edit library", systemImage: "slider.horizontal.3")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .padding(8)
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Split out to observe the history object directly.
private struct HistoryList: View {
    @ObservedObject var history: CommandHistory
    @ObservedObject var workspace: Workspace
    let query: String
    let semanticResults: [HistoryEntry]?

    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        // Literal matches first; the model's suggestions only fill the gap
        // when substring search came up short.
        let literal = history.filtered(query)
        let entries = (semanticResults?.isEmpty == false && literal.count < 3)
            ? semanticResults! : literal
        if entries.isEmpty {
            Text(query.isEmpty ? "Nothing run yet" : "No matches")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if semanticResults?.isEmpty == false && literal.count < 3 {
                        Text("matched by description")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                    }
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry, workspace: workspace)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var workspace: Workspace
    @State private var hovering = false

    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(entry.isRunning ? Theme.loadColor(50) : theme.textTertiary.opacity(0.6))
                .frame(width: 5, height: 5)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                if let triage = entry.triage {
                    Label(triage, systemImage: "sparkles")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 5) {
                    if entry.isRunning {
                        Text("running").foregroundStyle(Theme.loadColor(50))
                    } else if let duration = entry.durationText {
                        Text(duration)
                    }
                    if let code = entry.exitCode, code != 0 {
                        Text("exit \(code)").foregroundStyle(Theme.loadColor(200))
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 0)

            if hovering {
                // Insert rather than run: re-running a command from history
                // without looking at it is how people delete things twice.
                Button { workspace.focusedSession?.send(text: entry.command) } label: {
                    Image(systemName: "arrow.up.left.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
                .help("Insert into terminal")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(hovering ? theme.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { workspace.focusedSession?.send(text: entry.command) }
        .contextMenu {
            Button("Insert") { workspace.focusedSession?.send(text: entry.command) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.command, forType: .string)
            }
        }
    }
}

private struct LibraryRow: View {
    let snippet: Snippet
    @ObservedObject var workspace: Workspace
    @State private var hovering = false

    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: snippet.isPrompt ? "text.bubble" : "chevron.right.square")
                .font(.system(size: 9))
                .foregroundStyle(theme.textTertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.name)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(snippet.text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if !snippet.key.isEmpty {
                Text("⌃⌥\(snippet.key.uppercased())")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(hovering ? theme.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workspace.run(snippet) }
    }
}
