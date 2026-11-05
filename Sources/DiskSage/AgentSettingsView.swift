import AppKit
import SwiftUI

struct AgentSettingsView: View {
    @AppStorage("agentProvider") private var provider: AgentProvider = .codex
    @AppStorage("codexExecutablePath") private var codexPath = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("claudeExecutablePath") private var claudePath = ""
    @AppStorage("claudeModel") private var claudeModel = ""
    @AppStorage("agentMetadataConsent") private var codexConsent = false
    @AppStorage("claudeMetadataConsent") private var claudeConsent = false
    @State private var appleUnavailableReason = AppleAdvisor.unavailableReason
    @AppStorage("builtInAgentCleanupEnabled") private var builtInCleanup = false
    @AppStorage("agentCleanupPolicy") private var cleanupPolicy = AgentCleanupPolicy.confirm.rawValue

    var body: some View {
        Section("Cleanup Agent") {
            Picker("Agent", selection: $provider) {
                ForEach(AgentProvider.allCases) { agent in Text(agent.title).tag(agent) }
            }
            switch provider {
            case .codex:
                CLISettingsView(provider: .codex, executablePath: $codexPath, model: $codexModel, consent: $codexConsent)
            case .claude:
                CLISettingsView(provider: .claude, executablePath: $claudePath, model: $claudeModel, consent: $claudeConsent)
            case .ollama:
                OllamaSettingsView()
            case .apple:
                Label(appleUnavailableReason ?? "Available on this Mac", systemImage: appleUnavailableReason == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(appleUnavailableReason == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Text("Apple’s Foundation Models process cleanup metadata on this Mac. No CLI, account, or remote provider is used. If unavailable, DiskSage explains why; it never switches to a remote agent automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appleUnavailableReason = AppleAdvisor.unavailableReason
        }
        Section("Advisor tools") {
            Toggle("Allow built-in advisors to request cleanup", isOn: $builtInCleanup)
                .disabled(cleanupPolicy == AgentCleanupPolicy.disabled.rawValue)
            Text("Requests follow the cleanup access policy in MCP settings. Advisors receive metadata only.")
                .font(.caption).foregroundStyle(.secondary)
            Button("MCP settings…") {
                NotificationCenter.default.post(name: .diskSageOpenWindow, object: "mcp")
            }
        }
    }
}
