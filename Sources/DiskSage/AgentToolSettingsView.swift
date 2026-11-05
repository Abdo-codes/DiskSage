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
            Text("MCP clients can review paths, manage schedules and settings, request advice, and read cleanup logs. Selected-item deletion, custom folder authorization, and settings changes require in-app approval. Built-in advisors still receive metadata only.")
                .font(.callout).foregroundStyle(.secondary)
            if policy == AgentCleanupPolicy.automaticLowRisk.rawValue {
                Label("Authorized agents can permanently delete low-risk items without another confirmation.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Low-risk schedules can be activated by agents under Allow low-risk cleanup. Confirm mode saves their changes paused; enable them in Schedules. Custom folder changes always need your approval.")
                .font(.caption).foregroundStyle(.secondary)
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
