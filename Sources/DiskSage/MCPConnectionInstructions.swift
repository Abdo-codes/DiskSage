import Foundation

struct MCPConnectionInstructions {
    let executablePath: String
    static let verificationPrompt = "Use DiskSage to check its status and list my saved cleanup schedules."

    static var current: Self {
        Self(executablePath: Bundle.main.executableURL?.path ?? "/Applications/DiskSage.app/Contents/MacOS/DiskSage")
    }

    var launchCommand: String { "\(Self.shellQuote(executablePath)) --mcp" }
    var claudeCommand: String { "claude mcp add --transport stdio --scope user disksage -- \(launchCommand)" }
    var codexCommand: String { "codex mcp add disksage -- \(launchCommand)" }
    var configurationJSON: String {
        let config = ["mcpServers": ["disksage": ["command": executablePath, "args": ["--mcp"]] as [String: Any]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
