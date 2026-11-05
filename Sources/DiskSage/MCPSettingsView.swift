import SwiftUI

struct MCPSettingsView: View {
    let model: AppModel
    @State private var openedAt = Date()

    var body: some View {
        Form {
            MCPConnectionSetupView()
            Section("Verify connection") {
                MCPConnectionStatusView(serverError: model.agentToolConnectionError,
                    lastContact: model.lastMCPContact, startedAt: openedAt)
                Text("Ask your connected agent to check DiskSage, then look here for confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
                MCPCopyVerificationPrompt()
            }
            AgentToolSettingsView()
        }
        .formStyle(.grouped).padding(16)
    }
}
