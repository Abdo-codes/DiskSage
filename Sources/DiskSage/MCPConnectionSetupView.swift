import AppKit
import SwiftUI

struct MCPConnectionSetupView: View {
    private let instructions = MCPConnectionInstructions.current

    var body: some View {
        Section("Connect Claude Code or Codex") {
            Text("Copy a setup command and run it in Terminal, then start a new agent session. Keep DiskSage open while using its tools.")
                .font(.callout)
            MCPSetupCommandView(title: "Claude Code", command: instructions.claudeCommand)
            MCPSetupCommandView(title: "Codex", command: instructions.codexCommand)
            Text("Already configured? Check the existing disksage entry in your agent before running an add command.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Other MCP clients") {
                LabeledContent("Transport", value: "stdio")
                LabeledContent("Executable") {
                    Text(instructions.executablePath).textSelection(.enabled)
                        .font(.system(.caption, design: .monospaced))
                }
                LabeledContent("Arguments", value: "--mcp")
            }
            Text("get_status · scan · clean_low_risk · get_job")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Tools return totals and job status. File paths and project names remain in DiskSage. Built-in advisors use the same cleanup policy.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
                Button(copied ? "Copied" : "Copy Setup Command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.small)
            }
            Text(command).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .onChange(of: command) { _, _ in copied = false }
    }
}
