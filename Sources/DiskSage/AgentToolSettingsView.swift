import SwiftUI

struct AgentToolSettingsView: View {
    let model: AppModel
    @AppStorage("agentCleanupPolicy") private var policy = AgentCleanupPolicy.confirm.rawValue

    @AppStorage("builtInAgentCleanupEnabled") private var builtInCleanup = false

    var body: some View {
        Section("Agent cleanup access") {
            Picker("Cleanup requests", selection: $policy) {
                ForEach(AgentCleanupPolicy.allCases) { policy in Text(policy.title).tag(policy.rawValue) }
            }
            Toggle("Allow built-in advisors to request cleanup", isOn: $builtInCleanup)
                .disabled(policy == AgentCleanupPolicy.disabled.rawValue)
            Text("Allow Claude Code, Codex, and other MCP clients to request cleanup. Only DiskSage’s low-risk generated files are eligible. Every deletion uses the same safety checks and cleanup logs.")
                .font(.callout).foregroundStyle(.secondary)
            if policy == AgentCleanupPolicy.automaticLowRisk.rawValue {
                Label("Authorized agents can permanently delete low-risk items without another confirmation.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let error = model.agentToolConnectionError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                Label("Local server ready", systemImage: "checkmark.circle")
            }
            Text("Server readiness does not mean a client is connected. Check connections in Claude Code or Codex after setup.")
                .font(.caption).foregroundStyle(.secondary)
        }
        MCPConnectionSetupView()
    }
}
