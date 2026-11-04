import AppKit
import SwiftUI

@main
struct DiskSageApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("DiskSage", systemImage: "externaldrive.badge.checkmark") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("DiskSage Review", id: "review") {
            ReviewView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)

        Settings {
            SettingsView(model: model)
        }
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    @AppStorage("codexExecutablePath") private var codexExecutablePath = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("agentMetadataConsent") private var agentMetadataConsent = false
    @State private var showsAgentConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text("DiskSage")
                        .font(.headline)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isScanning || model.isAdvising || model.isCleaning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 16) {
                MetricView(label: "Free", value: model.freeSpaceBytes.diskSize)
                MetricView(label: "Candidates", value: model.totalCandidateBytes.diskSize)
                MetricView(label: "Selected", value: model.selectedBytes.diskSize)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Button("Scan", systemImage: "arrow.clockwise") {
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

            Button("Review \(model.candidates.count) Candidates", systemImage: "list.bullet.rectangle") {
                openWindow(id: "review")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.candidates.isEmpty)

            if model.isBusy {
                Button("Cancel Current Operation", role: .cancel) {
                    model.cancelCurrentOperation()
                }
            }

            Divider()

            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 350)
        .task {
            if model.candidates.isEmpty {
                model.scan()
            }
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
}

private struct MetricView: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
