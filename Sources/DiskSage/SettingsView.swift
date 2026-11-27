import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    static let windowSize = CGSize(width: 800, height: 600)
    static let minimumWindowSize = CGSize(width: 720, height: 520)
    @Bindable var model: AppModel
    @AppStorage("automaticCleanupEnabled") private var automaticCleanupEnabled = true
    @AppStorage("cleanupThresholdGiB") private var cleanupThresholdGiB = 15
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var cliSymlinkStatus = CLISymlinkInstaller.status()
    @State private var cliSymlinkError: String?
    @State private var cliOnPATH = CLISymlinkInstaller.isLocalBinOnPATH()
    @AppStorage("settingsSelectedTab") private var selectedTab = "general"

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
                Section {
                    cliSymlinkRow
                } header: {
                    Text("Command Line")
                } footer: {
                    Text(cliOnPATH
                         ? "Creates a symlink so `disksage scan` and `disksage explain <path>` work from Terminal."
                         : "Creates a symlink for `disksage scan` and `disksage explain <path>`. Add ~/.local/bin to your shell PATH if needed.")
                }
                KeepRulesSettingsView()
                ProjectCacheRulesSettingsView()
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
        .frame(minWidth: Self.minimumWindowSize.width, minHeight: Self.minimumWindowSize.height)
        .onAppear {
            if selectedTab == "tools" { selectedTab = "mcp" }
            refreshCLISymlinkStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .diskSageSettingsChanged)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
            refreshCLISymlinkStatus()
        }
    }

    @ViewBuilder
    private var cliSymlinkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLI symlink (`~/.local/bin/disksage`)")
                    Text(cliStatusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .installed = cliSymlinkStatus {
                    Button("Remove Symlink", action: removeCLISymlink)
                } else if case .pointsElsewhere(_, true) = cliSymlinkStatus {
                    Button("Remove Symlink", action: removeCLISymlink)
                    Button("Update CLI Symlink", action: installCLISymlink)
                } else if case .pointsElsewhere(_, false) = cliSymlinkStatus {
                    Button("Install CLI Symlink", action: installCLISymlink)
                        .disabled(true)
                } else {
                    Button("Install CLI Symlink", action: installCLISymlink)
                        .disabled(cliSymlinkStatus == .blockedByExistingFile)
                }
            }
            if let cliSymlinkError {
                Text(cliSymlinkError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var cliStatusDescription: String {
        switch cliSymlinkStatus {
        case let .installed(target):
            "Installed -> \(target)"
        case .notInstalled:
            "Not installed"
        case let .pointsElsewhere(target, true):
            "Points to another DiskSage build -> \(target)"
        case let .pointsElsewhere(target, false):
            "Another command symlink exists -> \(target)"
        case .blockedByExistingFile:
            "A non-symlink file already exists at ~/.local/bin/disksage"
        }
    }

    private func refreshCLISymlinkStatus() {
        cliSymlinkStatus = CLISymlinkInstaller.status()
        cliOnPATH = CLISymlinkInstaller.isLocalBinOnPATH()
    }

    private func installCLISymlink() {
        do {
            _ = try CLISymlinkInstaller.install()
            cliSymlinkError = nil
        } catch {
            cliSymlinkError = error.localizedDescription
        }
        refreshCLISymlinkStatus()
    }

    private func removeCLISymlink() {
        do {
            try CLISymlinkInstaller.uninstall()
            cliSymlinkError = nil
        } catch {
            cliSymlinkError = error.localizedDescription
        }
        refreshCLISymlinkStatus()
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
