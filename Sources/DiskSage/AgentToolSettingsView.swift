import SwiftUI

struct AgentToolSettingsView: View {
    @AppStorage("agentCleanupPolicy") private var policy = AgentCleanupPolicy.confirm.rawValue

    var body: some View {
        Section("Cleanup access") {
            Picker("Cleanup requests", selection: $policy) {
                ForEach(AgentCleanupPolicy.allCases) { policy in Text(policy.title).tag(policy.rawValue) }
            }
            Text("Selected-item deletion, custom folder authorization, and settings changes require approval in DiskSage. This policy also applies to cleanup requests from enabled built-in advisors.")
                .font(.callout).foregroundStyle(.secondary)
            if policy == AgentCleanupPolicy.automaticLowRisk.rawValue {
                Label("Authorized agents can permanently delete low-risk items without another confirmation.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Low-risk schedules can be activated by agents under Allow low-risk cleanup. Confirm mode saves their changes paused; enable them in Schedules. Custom folder changes always need your approval.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
