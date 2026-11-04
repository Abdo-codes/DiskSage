import AppKit
import ServiceManagement
import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel
    @AppStorage("codexExecutablePath") private var codexExecutablePath = "/opt/homebrew/bin/codex"
    @AppStorage("codexModel") private var codexModel = ""
    @State private var showsDeletionConfirmation = false

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
            Text("DiskSage will delete only the allowlisted candidates shown here. This cannot be undone.")
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
                .disabled(model.isScanning)
                Button("Ask Codex", systemImage: "sparkles") {
                    model.askCodex(executablePath: codexExecutablePath, model: codexModel)
                }
                .disabled(model.candidates.isEmpty || model.isAdvising)
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
            .disabled(model.selection.isEmpty || model.isCleaning)
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
}

struct SettingsView: View {
    @AppStorage("codexExecutablePath") private var codexExecutablePath = "/opt/homebrew/bin/codex"
    @AppStorage("codexModel") private var codexModel = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Codex Agent") {
                TextField("Executable", text: $codexExecutablePath)
                TextField("Model override", text: $codexModel, prompt: Text("Use Codex default"))
                Text("DiskSage uses your existing local Codex sign-in. Candidate metadata is sent to an ephemeral, read-only agent session.")
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
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 520, height: 360)
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
