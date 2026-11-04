import Foundation

struct MCPConnectionInstructions {
    let executablePath: String

    static var current: Self {
        Self(executablePath: Bundle.main.executableURL?.path ?? "/Applications/DiskSage.app/Contents/MacOS/DiskSage")
    }

    var launchCommand: String { "\(Self.shellQuote(executablePath)) --mcp" }
    var claudeCommand: String { "claude mcp add --transport stdio --scope user disksage -- \(launchCommand)" }
    var codexCommand: String { "codex mcp add disksage -- \(launchCommand)" }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
