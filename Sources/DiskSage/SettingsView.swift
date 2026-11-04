import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("automaticCleanupEnabled") private var automaticCleanupEnabled = true
    @AppStorage("cleanupThresholdGiB") private var cleanupThresholdGiB = 15
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @AppStorage("settingsSelectedTab") private var selectedTab = "agent"

    var body: some View {
        TabView(selection: $selectedTab) {
            Form { AgentSettingsView() }
                .formStyle(.grouped)
                .padding(16)
                .tabItem { Label("Agent", systemImage: "sparkles") }
                .tag("agent")
            Form { AgentToolSettingsView(model: model) }
                .formStyle(.grouped)
                .padding(16)
                .tabItem { Label("Agent Tools", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("tools")
            Form {
                Section("Safety") {
                    Label("Advisors receive metadata only. Authorized tools can request low-risk cleanup.", systemImage: "lock.shield")
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
            .padding(16)
            .tabItem { Label("General & Safety", systemImage: "gearshape") }
            .tag("general")
        }
        .padding(.top, 12)
        .frame(width: 600, height: 540)
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
