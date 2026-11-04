import AppKit
import ServiceManagement
import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel
    @AppStorage("codexExecutablePath") private var codexExecutablePath = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("agentMetadataConsent") private var agentMetadataConsent = false
    @State private var showsDeletionConfirmation = false
    @State private var showsAgentConsent = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            candidateTable
            Divider()
            footer
        }
        .alert("Permanently delete selected items?", isPresented: $showsDeletionConfirmation) {
            Button("Delete \(model.selectedBytes.diskSize)", role: .destructive) {
                model.deleteSelection()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deletionConfirmationMessage)
        }
        .alert("Send cleanup metadata to Codex?", isPresented: $showsAgentConsent) {
            Button("Allow and Continue") {
                agentMetadataConsent = true
                model.askCodex(executablePath: codexExecutablePath, model: codexModel)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("DiskSage sends category, size, risk, and reason to your configured Codex provider. File paths and project names are excluded.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cleanup Review")
                        .font(.title2.weight(.semibold))
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan Again", systemImage: "arrow.clockwise") {
                    model.scan()
                }
                .disabled(model.isBusy)
                Button("Ask Codex", systemImage: "sparkles") {
                    if agentMetadataConsent {
                        model.askCodex(executablePath: codexExecutablePath, model: codexModel)
                    } else {
                        showsAgentConsent = true
                    }
                }
                .disabled(model.candidates.isEmpty || model.isBusy)
            }

            if !model.recommendationSummary.isEmpty {
                Label(model.recommendationSummary, systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
            }
        }
        .padding(18)
    }

    private var candidateTable: some View {
        Table(model.candidates, selection: $model.selection) {
            TableColumn("Item") { candidate in
                HStack {
                    Image(systemName: candidate.category.systemImage)
                        .foregroundStyle(color(for: candidate.risk))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(candidate.name)
                        Text(candidate.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 280, ideal: 420)

            TableColumn("Size") { candidate in
                Text(candidate.size.diskSize)
                    .monospacedDigit()
            }
            .width(80)

            TableColumn("Risk") { candidate in
                Text(candidate.risk.title)
                    .foregroundStyle(color(for: candidate.risk))
            }
            .width(80)

            TableColumn("Agent") { candidate in
                if let recommendation = model.recommendations[candidate.id] {
                    Text(recommendation.decision.rawValue.capitalized)
                        .help(recommendation.rationale)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if model.candidates.isEmpty && !model.isScanning {
                ContentUnavailableView(
                    "No Candidates",
                    systemImage: "checkmark.circle",
                    description: Text("Run a scan to find generated files and caches.")
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("\(model.selection.count) selected · \(model.selectedBytes.diskSize)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal", systemImage: "folder") {
                guard let candidate = model.selectedCandidates.first else { return }
                NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
            }
            .disabled(model.selection.count != 1)

            Button("Delete Selected", systemImage: "trash", role: .destructive) {
                showsDeletionConfirmation = true
            }
            .disabled(model.selection.isEmpty || model.isBusy)
        }
        .padding(14)
    }

    private func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    private var deletionConfirmationMessage: String {
        let sensitiveCount = model.selectedCandidates.filter { $0.risk == .high }.count
        let paths = model.selectedCandidates.prefix(3).map(\.url.path).joined(separator: "\n")
        let remainder = max(0, model.selectedCandidates.count - 3)
        let sensitiveWarning = sensitiveCount > 0
            ? "\n\nWarning: \(sensitiveCount) sensitive item(s), such as archives or simulator data, are selected."
            : ""
        let remainderText = remainder > 0 ? "\n…and \(remainder) more" : ""
        return "DiskSage will permanently delete:\n\(paths)\(remainderText)\(sensitiveWarning)"
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("codexExecutablePath") private var codexExecutablePath = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("agentMetadataConsent") private var agentMetadataConsent = false
    @AppStorage("automaticCleanupEnabled") private var automaticCleanupEnabled = true
    @AppStorage("cleanupThresholdGiB") private var cleanupThresholdGiB = 15
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Codex Agent") {
                TextField("Executable override", text: $codexExecutablePath, prompt: Text("Detect automatically"))
                TextField("Model override", text: $codexModel, prompt: Text("Use Codex default"))
                Toggle("Allow anonymized cleanup metadata to be sent to Codex", isOn: $agentMetadataConsent)
                Text("DiskSage uses your existing local Codex sign-in. Paths and project names are excluded. The provider may be remote depending on your Codex account configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Safety") {
                Label("Agents can recommend, but cannot add paths or delete files.", systemImage: "lock.shield")
                Label("High-risk items require manual selection and confirmation.", systemImage: "hand.raised")
            }

            Section("General") {
                Toggle("Launch DiskSage at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Clean safe items automatically when disk space is low", isOn: $automaticCleanupEnabled)
                Stepper("Cleanup threshold: \(cleanupThresholdGiB) GiB", value: $cleanupThresholdGiB, in: 5...100, step: 5)
                    .disabled(!automaticCleanupEnabled)
                LabeledContent("Last automatic cleanup", value: model.automaticCleanupSummary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 560, height: 470)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
