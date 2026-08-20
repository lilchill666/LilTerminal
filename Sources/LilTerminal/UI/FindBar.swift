import SwiftUI

/// Inline find bar for the focused pane.
///
/// Replaces the modal prompt that stood in for this: a dialog blocks the
/// terminal, cannot show a match count, and makes stepping through results
/// needlessly heavy.
struct FindBar: View {
    @ObservedObject var workspace: Workspace
    @Binding var isPresented: Bool
    @State private var term = ""
    @State private var status: String?
    @FocusState private var focused: Bool

    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)

            TextField("Find", text: $term)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .focused($focused)
                .onSubmit { step(forward: true) }
                .frame(width: 160)

            if let status {
                Text(status)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }

            Divider().frame(height: 12)

            Button { step(forward: false) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .help("Previous (⌘⇧G)")
            Button { step(forward: true) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .help("Next (⌘G)")
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Close (Esc)")
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.textSecondary)
        // Hug the content: a full-width bar covers far more of the terminal
        // than it needs to.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .surface(workspace.prefs.statusBarAppearance, slot: .status, theme: theme,
                 cornerRadius: CGFloat(workspace.prefs.pillCornerRadius))
        .onAppear {
            // Seed from the selection, the way every macOS find bar does.
            if let selected = workspace.focusedSession?.terminalView.selectedText,
               !selected.isEmpty, selected.count < 200 {
                term = selected
            }
            focused = true
        }
        .onExitCommand { close() }
        .onChange(of: workspace.findTrigger) { _, _ in
            step(forward: workspace.findForward)
        }
    }

    private func step(forward: Bool) {
        guard let view = workspace.focusedSession?.terminalView, !term.isEmpty else { return }
        status = view.find(term, forward: forward) ? nil : "no match"
    }

    private func close() {
        isPresented = false
        workspace.focusedSession?.terminalView.clearSelection()
    }
}
