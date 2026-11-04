import Foundation
import Darwin

enum CodexAdvisorError: LocalizedError {
    case executableNotFound
    case failed(String)
    case invalidResponse
    case untrustedExecutable(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found. Install or sign in to Codex first."
        case let .failed(message):
            "Codex advisor failed: \(message)"
        case .invalidResponse:
            "Codex returned an unreadable recommendation."
        case let .untrustedExecutable(reason):
            "Codex executable was refused: \(reason)"
        case .timedOut:
            "Codex did not respond within \(CodexAdvisor.timeoutSeconds) seconds."
        }
    }
}

struct CodexAdvisor: Sendable {
    static let timeoutSeconds: Int = 90

    func recommend(candidates: [CleanupCandidate], executablePath: String, model: String, allowsCleanupRequests: Bool = false) async throws -> AgentResponse {
        let json = try AdvisorContract.metadataJSON(candidates)

        let controller = AdvisorProcessController()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let response = try runCodex(
                    json: json,
                    executablePath: executablePath,
                    model: model,
                    allowsCleanupRequests: allowsCleanupRequests,
                    controller: controller
                )
                try validate(response, expectedIDs: Set(candidates.map(\.id)))
                return response
            }.value
        } onCancel: {
            controller.terminate()
        }
    }

    static func discoverExecutable(preferredPath: String = "") -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [preferredPath]
            + [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                home.appending(path: ".local/bin/codex").path,
                home.appending(path: ".npm-global/bin/codex").path
            ]
        return candidates
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func runCodex(
        json: String,
        executablePath: String,
        model: String,
        allowsCleanupRequests: Bool,
        controller: AdvisorProcessController
    ) throws -> AgentResponse {
        guard let executable = Self.discoverExecutable(preferredPath: executablePath) else {
            throw CodexAdvisorError.executableNotFound
        }
        try validateExecutable(executable)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "DiskSage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appending(path: "recommendation.json")
        let schemaURL = temporaryDirectory.appending(path: "schema.json")
        let stderrURL = temporaryDirectory.appending(path: "stderr.log")
        try AdvisorContract.responseSchema.write(to: schemaURL, atomically: true, encoding: .utf8)

        let prompt = AdvisorContract.prompt(metadata: json, allowsCleanupRequests: allowsCleanupRequests)

        var arguments = [
            "exec",
            "--ephemeral",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--output-schema", schemaURL.path,
            "-C", temporaryDirectory.path,
            "-o", outputURL.path
        ]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--model", model]
        }
        arguments.append(prompt)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = minimalEnvironment()
        process.standardOutput = FileHandle.nullDevice
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { stderrHandle.closeFile() }
        process.standardError = stderrHandle
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try controller.launch(process)
        if completion.wait(timeout: .now() + Double(Self.timeoutSeconds)) == .timedOut {
            controller.terminate()
            if completion.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            controller.clear()
            throw CodexAdvisorError.timedOut
        }
        controller.clear()

        guard process.terminationStatus == 0 else {
            let diagnostic = (try? String(contentsOf: stderrURL, encoding: .utf8))?
                .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
            throw CodexAdvisorError.failed("status \(process.terminationStatus). \(diagnostic)")
        }
        let responseData = try Data(contentsOf: outputURL)
        let cleaned = stripMarkdownFences(String(decoding: responseData, as: UTF8.self))
        guard let cleanedData = cleaned.data(using: .utf8),
              let response = try? JSONDecoder().decode(AgentResponse.self, from: cleanedData) else {
            throw CodexAdvisorError.invalidResponse
        }
        return response
    }

    func validate(_ response: AgentResponse, expectedIDs: Set<UUID>) throws {
        do { try AdvisorContract.validate(response, expectedIDs: expectedIDs) }
        catch { throw CodexAdvisorError.invalidResponse }
    }

    private func validateExecutable(_ executable: URL) throws {
        var info = stat()
        guard lstat(executable.path, &info) == 0 else {
            throw CodexAdvisorError.executableNotFound
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw CodexAdvisorError.untrustedExecutable("resolved path is not a regular file")
        }
        guard (info.st_mode & S_IWOTH) == 0 else {
            throw CodexAdvisorError.untrustedExecutable("binary is writable by every user")
        }
        let owner = uid_t(getuid())
        guard info.st_uid == 0 || info.st_uid == owner else {
            throw CodexAdvisorError.untrustedExecutable("binary has an unexpected owner")
        }
    }

    private func minimalEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME"]
        var result = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
            source[key].map { (key, $0) }
        })
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        return result
    }

    private func stripMarkdownFences(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
