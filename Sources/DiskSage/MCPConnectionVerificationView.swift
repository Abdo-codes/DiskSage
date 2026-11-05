import AppKit
import SwiftUI

struct MCPConnectionVerificationView: View {
    let serverError: String?
    let lastContact: Date?
    let startedAt: Date

    var body: some View {
        Form {
            Section("Check the connection") {
                Text("Start a new session in your agent, or reconnect its DiskSage MCP server, then ask it to check DiskSage.")
                MCPCopyVerificationPrompt()
            }
            Section("This running app") {
                MCPConnectionStatusView(serverError: serverError, lastContact: lastContact, startedAt: startedAt)
            }
            Section {
                Text("Connect each agent separately. Verification confirms a client reached DiskSage; it does not verify advisor sign-in or quota.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Keep DiskSage running while using MCP tools. Connection is optional, so you can finish now and return from About later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(16)
    }
}

struct MCPConnectionStatusView: View {
    let serverError: String?
    let lastContact: Date?
    let startedAt: Date
    var body: some View {
        if let serverError {
            Label("Local server unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(serverError).font(.caption).textSelection(.enabled)
        } else if MCPOnboardingPreferences.isVerified(since: startedAt, lastContact: lastContact, serverError: serverError) {
            Label("Connection verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if let lastContact {
                Text("A client reached DiskSage at \(lastContact, format: .dateTime.hour().minute().second()).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("Waiting for an agent tool call", systemImage: "arrow.triangle.2.circlepath")
            Text("The local server is ready. A tool call received after opening this screen confirms that a client can reach the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MCPCopyVerificationPrompt: View {
    @State private var copied = false
    var body: some View {
        Text(MCPConnectionInstructions.verificationPrompt)
            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        Button(copied ? "Copied" : "Copy test prompt", systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(MCPConnectionInstructions.verificationPrompt, forType: .string)
        }
    }
}
