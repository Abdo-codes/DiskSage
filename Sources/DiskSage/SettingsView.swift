import ServiceManagement
import SwiftUI

struct SettingsView: View {
    static let windowSize = CGSize(width: 800, height: 600)
    @Bindable var model: AppModel
    @AppStorage("automaticCleanupEnabled") private var automaticCleanupEnabled = true
    @AppStorage("cleanupThresholdGiB") private var cleanupThresholdGiB = 15
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @AppStorage("settingsSelectedTab") private var selectedTab = "agent"

    var body: some View {
        TabView(selection: $selectedTab) {
            ScheduleSettingsView(model: model)
                .tabItem { Label("Schedules", systemImage: "calendar.badge.clock") }
                .tag("schedules")
            Form { AgentSettingsView() }
                .formStyle(.grouped)
                .padding(16)
                .tabItem { Label("Agent", systemImage: "sparkles") }
                .tag("agent")
            MCPSettingsView(model: model)
                .tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("mcp")
            Form {
                Section("Safety") {
                    Label("Advisors receive metadata only. Authorized tools can request low-risk cleanup.", systemImage: "lock.shield")
                    Label("Scanned high-risk items require manual confirmation. Custom folder schedules require explicit authorization.", systemImage: "hand.raised")
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
                        .onChange(of: automaticCleanupEnabled) { _, _ in model.store.send(.monitoringPreferencesChanged) }
                    Stepper("Cleanup threshold: \(cleanupThresholdGiB) GiB", value: $cleanupThresholdGiB, in: 5...100, step: 5)
                        .disabled(!automaticCleanupEnabled)
                        .onChange(of: cleanupThresholdGiB) { _, _ in model.store.send(.monitoringPreferencesChanged) }
                    LabeledContent("Last automatic cleanup", value: model.automaticCleanupSummary)
                }
            }
            .formStyle(.grouped)
            .padding(16)
            .tabItem { Label("General & Safety", systemImage: "gearshape") }
            .tag("general")
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .padding(.top, 12)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .onAppear { if selectedTab == "tools" { selectedTab = "mcp" } }
        .onReceive(NotificationCenter.default.publisher(for: .diskSageSettingsChanged)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
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
