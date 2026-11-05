import AppKit
import ComposableArchitecture
import SwiftUI

struct MCPConnectionSetupView: View {
    var instructions = MCPConnectionInstructions.current
    @State private var store = Store(initialState: MCPIntegrationFeature.State()) { MCPIntegrationFeature() }

    var body: some View {
        Section("Connect an agent") {
            Text("Connect an installed client in one click. Then start a new chat or reconnect its DiskSage MCP server. Keep DiskSage running while using its tools.")
                .font(.callout)
            ForEach(MCPClient.allCases) { client in
                MCPClientConnectionRow(client: client, status: store.statuses[client] ?? .unchecked,
                    busy: store.busy.contains(client), connect: { store.send(.connect(client, instructions.executablePath)) })
            }
            Button("Refresh clients", systemImage: "arrow.clockwise") { refresh() }
                .disabled(!store.busy.isEmpty)
            DisclosureGroup("Manual setup & other clients") {
                MCPSetupCommandView(title: "Claude Code", command: instructions.claudeCommand)
                MCPSetupCommandView(title: "Codex", command: instructions.codexCommand)
                Text("Other clients: choose stdio and merge this entry into their MCP configuration.")
                    .font(.caption).foregroundStyle(.secondary)
                MCPSetupCommandView(title: "MCP configuration JSON", command: instructions.configurationJSON)
                LabeledContent("Transport", value: "stdio · --mcp")
                Text("An existing disksage entry with different settings is left intact. Review it in your client before changing it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("MCP clients can read paths and logs. Cleanup follows your MCP access policy. No separate skill package is required.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: instructions.executablePath) { refresh() }
    }

    private func refresh() {
        for client in MCPClient.allCases { store.send(.check(client, instructions.executablePath)) }
    }
}

private struct MCPClientConnectionRow: View {
    let client: MCPClient
    let status: MCPRegistrationStatus
    let busy: Bool
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(client.title).fontWeight(.medium)
                    MCPClientRegistrationLabel(status: status)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Checking \(client.title)") }
                if status != .configured {
                    Button("Connect", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || status != .notConfigured)
                        .accessibilityLabel("Connect \(client.title)")
                }
            }
            if case let .failed(message) = status { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 4)
    }
}

private struct MCPClientRegistrationLabel: View {
    let status: MCPRegistrationStatus
    var body: some View {
        Group {
            switch status {
            case .unchecked: Text("Checking configuration…")
            case .notInstalled: Text("CLI not found. Use Manual setup or set its path in Agent settings.")
            case .notConfigured: Text("Ready to connect")
            case .configured: Label("Configured · reconnect your client to use", systemImage: "checkmark.circle")
            case .conflict: Label("Existing entry needs review in your client", systemImage: "exclamationmark.triangle")
            case .failed: Label("Couldn’t configure client", systemImage: "exclamationmark.triangle")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

private struct MCPSetupCommandView: View {
    let title: LocalizedStringKey
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.small)
                .accessibilityLabel(copied ? Text("Copied \(Text(title))") : Text("Copy \(Text(title))"))
            }
            Text(command).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .onChange(of: command) { _, _ in copied = false }
    }
}
