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
            SettingsView()
        }
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    @AppStorage("codexExecutablePath") private var codexExecutablePath = "/opt/homebrew/bin/codex"
    @AppStorage("codexModel") private var codexModel = ""

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
                .disabled(model.isScanning)

                Button("Ask Codex", systemImage: "sparkles") {
                    model.askCodex(executablePath: codexExecutablePath, model: codexModel)
                }
                .disabled(model.candidates.isEmpty || model.isAdvising)
            }

            Button("Review \(model.candidates.count) Candidates", systemImage: "list.bullet.rectangle") {
                openWindow(id: "review")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.candidates.isEmpty)

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
