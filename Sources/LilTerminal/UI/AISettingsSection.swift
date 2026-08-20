import SwiftUI

/// The AI pane of Settings.
///
/// Everything here defaults to off. The impact readout is the important part:
/// choosing a local model without being told what it costs this particular Mac
/// is how people end up swapping and blaming the app.
struct AISettingsSection: View {
    @ObservedObject var workspace: Workspace
    /// Observed directly: status lives on the coordinator, and a view watching
    /// only Workspace never hears it change.
    @ObservedObject var ai: AICoordinator
    @Binding var prefs: Preferences
    @StateObject private var ollama = OllamaManager()
    @State private var refreshing = false

    private var current: Preferences { workspace.prefs }

    var body: some View {
        Group {
            SwiftUI.Section {
                Toggle("Enable local AI features", isOn: $prefs.aiEnabled)
            } footer: {
                Text("Off by default. Everything runs on this Mac — nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if current.aiEnabled {
                backendSection
                impactSection
                featuresSection
                privacySection
            }
        }
        .task {
            ollama.onBecameAvailable = { [weak ai] in ai?.recheck() }
            await reload()
        }
        .onChange(of: current.aiBackend) { _, _ in Task { await reload() } }
        .onDisappear { ollama.cancelAll() }
    }

    // MARK: Backend

    @ViewBuilder private var backendSection: some View {
        SwiftUI.Section {
            Picker("Runs on", selection: $prefs.aiBackend) {
                ForEach(AIBackendKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(current.aiBackend.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if current.aiBackend == .ollama {
                if !ollama.isRunning {
                    HStack(spacing: 8) {
                        Text("Ollama is not running")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Start", action: ollama.startServer)
                        Button(refreshing ? "…" : "Recheck") { Task { await reload() } }
                    }
                }
                modelSelector
            }

            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ai.isAvailable ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(ai.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button { ai.recheck() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Check again")
                }
            }
        } header: {
            Text("Model")
        }
    }

    // MARK: Model selector

    @ViewBuilder private var modelSelector: some View {
        if !ollama.installed.isEmpty {
            Picker("Model", selection: $prefs.aiOllamaModel) {
                ForEach(ollama.installed, id: \.name) { model in
                    Text("\(model.name)  ·  \((model.size ?? 0).humanBytes)").tag(model.name)
                }
            }
        }

        // Shown outright rather than behind a disclosure: with no model
        // installed, the list of models to install is the whole point of the
        // screen, and hiding it behind a click is backwards.
        if ollama.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                Text(ollama.installed.isEmpty ? "Install a model" : "Other models")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(OllamaManager.catalog) { entry in
                    catalogRow(entry)
                }
                Text("Downloads go through Ollama and are shared with anything else using it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }

        if let error = ollama.lastError {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func catalogRow(_ entry: ModelCatalogEntry) -> some View {
        let installed = ollama.isInstalled(entry.name)
        let download = ollama.downloads[entry.name]
        // Every candidate is costed against this Mac, not in the abstract.
        let impact = DeviceImpact.forLocalModel(
            named: entry.name,
            bytes: ollama.size(of: entry.name) ?? entry.approximateBytes)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(entry.approximateBytes.humanBytes)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if installed {
                            Text("installed")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(entry.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(impact.severity.label) on this Mac")
                        .font(.caption2)
                        .foregroundStyle(color(for: impact.severity))
                }

                Spacer(minLength: 8)

                if let download {
                    Button("Cancel") { ollama.cancel(entry.name) }
                        .controlSize(.small)
                } else if installed {
                    Button("Use") { prefs.aiOllamaModel = entry.name }
                        .controlSize(.small)
                        .disabled(current.aiOllamaModel == entry.name)
                } else {
                    Button("Download") { ollama.pull(entry.name) }
                        .controlSize(.small)
                }
            }

            if let download {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: download.fraction)
                    HStack {
                        Text(download.status)
                        Spacer()
                        if download.total > 0 {
                            Text("\(download.completed.humanBytes) / \(download.total.humanBytes)")
                                .font(.system(size: 9, design: .monospaced))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Impact

    @ViewBuilder private var impactSection: some View {
        let impact = currentImpact
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: impact.severity))
                        .foregroundStyle(color(for: impact.severity))
                    Text(impact.headline)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(impact.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let fraction = impact.memoryFraction {
                    ProgressView(value: min(fraction, 1))
                        .tint(color(for: impact.severity))
                }

                Text("This Mac: \(DeviceImpact.machineSummary)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("Impact on this Mac")
        }
    }

    private var currentImpact: DeviceImpact {
        switch current.aiBackend {
        case .appleOnDevice:
            return .appleOnDevice
        case .ollama:
            return .forLocalModel(named: current.aiOllamaModel,
                                  bytes: ollama.size(of: current.aiOllamaModel))
        }
    }

    private func icon(for severity: DeviceImpact.Severity) -> String {
        switch severity {
        case .negligible, .light: return "checkmark.circle.fill"
        case .moderate:           return "gauge.medium"
        case .heavy:              return "gauge.high"
        case .excessive:          return "exclamationmark.triangle.fill"
        }
    }

    private func color(for severity: DeviceImpact.Severity) -> Color {
        switch severity {
        case .negligible, .light: return .green
        case .moderate:           return .yellow
        case .heavy:              return .orange
        case .excessive:          return .red
        }
    }

    // MARK: Features

    @ViewBuilder private var featuresSection: some View {
        SwiftUI.Section {
            Toggle("Tab activity — “needs you”, “working”, “failed”", isOn: $prefs.aiActivityEnabled)
            Toggle("Auto-name tabs from what they are doing", isOn: $prefs.aiAutoNameEnabled)
            Toggle("Explain failed commands in History", isOn: $prefs.aiTriageEnabled)
            Toggle("Search history by description", isOn: $prefs.aiSearchEnabled)
        } header: {
            Text("Features")
        } footer: {
            Text("Each runs independently. Turning one off stops it being called at all.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Privacy / cost

    @ViewBuilder private var privacySection: some View {
        SwiftUI.Section {
            Toggle("Skip the tab you are looking at", isOn: $prefs.aiSkipFocusedTab)
            LabeledContent("Check every") {
                HStack(spacing: 8) {
                    Slider(value: $prefs.aiActivityCooldown, in: 10...120, step: 5)
                    Text("\(Int(current.aiActivityCooldown))s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        } header: {
            Text("When it runs")
        } footer: {
            Text("A tab is only read when its output has actually changed since the last check. Individual tabs can be excluded from the sidebar's context menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        refreshing = true
        await ollama.refresh()
        refreshing = false
    }
}
