import Darwin
import Foundation

struct ClaudeAdvisor: Sendable {
    var timeout: TimeInterval = 90

    static func discoverExecutable(preferredPath: String = "") -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [preferredPath, home.appending(path: ".local/bin/claude").path,
                "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                home.appending(path: ".npm-global/bin/claude").path]
            .filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func recommend(candidates: [CleanupCandidate], executablePath: String, model: String, allowsCleanupRequests: Bool = false) async throws -> AgentResponse {
        let prompt = AdvisorContract.prompt(metadata: try AdvisorContract.metadataJSON(candidates), allowsCleanupRequests: allowsCleanupRequests)
        let controller = AdvisorProcessController()
        return try await withTaskCancellationHandler {
            let response = try await Task.detached(priority: .userInitiated) {
                try run(prompt: prompt, executablePath: executablePath, model: model, controller: controller)
            }.value
            try Task.checkCancellation()
            try AdvisorContract.validate(response, expectedIDs: Set(candidates.map(\.id)))
            return response
        } onCancel: { controller.terminate() }
    }

    static func arguments(prompt: String, model: String) -> [String] {
        var values = ["--print", "--output-format", "json", "--json-schema", AdvisorContract.responseSchema,
                      "--tools", "", "--disallowedTools", "mcp__*", "--strict-mcp-config",
                      "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence",
                      "--disable-slash-commands", "--safe-mode", "--setting-sources", "",
                      "--settings", "{\"disableAllHooks\":true}", "--system-prompt", AdvisorContract.instructions]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values += ["--model", model] }
        return values + ["--", prompt]
    }

    static func decode(_ data: Data) throws -> AgentResponse {
        struct Envelope: Decodable {
            let subtype: String
            let is_error: Bool?
            let result: String?
            let structured_output: AgentResponse?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw AdvisorError.invalidResponse
        }
        guard envelope.subtype == "success", envelope.is_error != true else {
            throw AdvisorError.failed(ClaudeFailureMessage.describe(data))
        }
        if let response = envelope.structured_output { return response }
        if let result = envelope.result,
           let response = try? JSONDecoder().decode(AgentResponse.self, from: Data(result.utf8)) { return response }
        throw AdvisorError.invalidResponse
    }

    private func run(prompt: String, executablePath: String, model: String,
                     controller: AdvisorProcessController) throws -> AgentResponse {
        guard let executable = Self.discoverExecutable(preferredPath: executablePath) else {
            throw AdvisorError.unavailable("Claude Code was not found. Install it and run ‘claude auth login’ first.")
        }
        var info = stat()
        guard lstat(executable.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & S_IWOTH) == 0, info.st_uid == 0 || info.st_uid == getuid() else {
            throw AdvisorError.unavailable("Claude executable was refused: check its ownership and permissions.")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "DiskSage-Claude-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "response.json")
        let errors = directory.appending(path: "stderr.log")
        for file in [output, errors] {
            _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(prompt: prompt, model: model)
        process.currentDirectoryURL = directory
        let environment = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CLAUDE_CONFIG_DIR"]
        process.environment = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in environment[key].map { (key, $0) } })
        process.environment?["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        defer { controller.clear() }
        try controller.launch(process)
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            controller.terminate()
            if completion.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            throw AdvisorError.timedOut
        }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard process.terminationStatus == 0 else {
            let data = size <= 2_000_000 ? try? Data(contentsOf: output) : nil
            throw AdvisorError.failed(ClaudeFailureMessage.describe(data, exitStatus: process.terminationStatus))
        }
        guard size <= 2_000_000 else { throw AdvisorError.invalidResponse }
        return try Self.decode(Data(contentsOf: output))
    }
}
