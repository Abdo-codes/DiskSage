import Foundation

enum MCPClient: String, CaseIterable, Identifiable, Sendable {
    case claude, codex
    var id: Self { self }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
    var readArguments: [String] { ["mcp", "get", "disksage"] + (self == .codex ? ["--json"] : []) }
    func addArguments(path: String) -> [String] {
        ["mcp", "add"] + (self == .claude ? ["--transport", "stdio", "--scope", "user"] : [])
            + ["disksage", "--", path, "--mcp"]
    }
}

enum MCPRegistrationStatus: Equatable, Sendable {
    case unchecked, notInstalled, notConfigured, configured, conflict, failed(String)
}

/// Serializes each read/add/read transaction across Settings and onboarding.
actor MCPRegistrationService {
    static let shared = MCPRegistrationService()
    typealias Resolve = @Sendable (MCPClient) -> URL?
    typealias Run = @Sendable (URL, [String]) throws -> MCPCommandOutput
    private let resolve: Resolve
    private let run: Run

    init(resolve: @escaping Resolve = { client in
        let key = client == .claude ? "claudeExecutablePath" : "codexExecutablePath"
        let path = UserDefaults.standard.string(forKey: key) ?? ""
        return client == .claude ? ClaudeAdvisor.discoverExecutable(preferredPath: path) : CodexAdvisor.discoverExecutable(preferredPath: path)
    }, run: @escaping Run = { try MCPCommandRunner.run(executable: $0, arguments: $1) }) {
        self.resolve = resolve
        self.run = run
    }

    func perform(client: MCPClient, path: String, connect: Bool) -> MCPRegistrationStatus {
        guard let executable = resolve(client) else { return .notInstalled }
        do {
            let current = try inspect(client: client, executable: executable, path: path)
            guard connect, current == .notConfigured else { return current }
            let result = try run(executable, client.addArguments(path: path))
            guard result.exitCode == 0 else { return .failed("Setup could not be saved. Use Manual setup below to check your client configuration.") }
            let verified = try inspect(client: client, executable: executable, path: path)
            guard verified == .configured else { return .failed("The client did not confirm the saved configuration. Check Manual setup before trying again.") }
            return verified
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func inspect(client: MCPClient, executable: URL, path: String) throws -> MCPRegistrationStatus {
        let output = try run(executable, client.readArguments)
        if output.exitCode != 0 {
            let message = output.text.lowercased()
            if message.contains("no mcp server named") || message.contains("no mcp server found with name") { return .notConfigured }
            return .failed("Could not read this client's configuration. Use Manual setup below; no settings were changed.")
        }
        if client == .codex {
            guard let data = output.text.data(using: .utf8),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let transport = config["transport"] as? [String: Any] else {
                return .failed("The client returned an unfamiliar configuration format. Use Manual setup below.")
            }
            return config["enabled"] as? Bool == true && transport["type"] as? String == "stdio"
                && transport["command"] as? String == path && transport["args"] as? [String] == ["--mcp"] ? .configured : .conflict
        }
        let lines = output.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.contains("Scope: User config (available in all your projects)") && lines.contains("Type: stdio")
            && lines.contains("Command: \(path)") && lines.contains("Args: --mcp") ? .configured : .conflict
    }
}
