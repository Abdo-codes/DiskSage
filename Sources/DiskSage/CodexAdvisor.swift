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
            "Codex did not respond within 90 seconds."
        }
    }
}

struct CodexAdvisor: Sendable {
    private struct AdvisorCandidate: Codable {
        let id: UUID
        let category: String
        let sizeBytes: Int64
        let risk: String
        let reason: String
    }

    func recommend(candidates: [CleanupCandidate], executablePath: String, model: String) async throws -> AgentResponse {
        let payload = candidates.map {
            AdvisorCandidate(
                id: $0.id,
                category: $0.category.rawValue,
                sizeBytes: $0.size,
                risk: $0.risk.title,
                reason: $0.reason
            )
        }
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)

        let controller = ProcessController()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let response = try runCodex(
                    json: json,
                    executablePath: executablePath,
                    model: model,
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
        controller: ProcessController
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
        try Self.responseSchema.write(to: schemaURL, atomically: true, encoding: .utf8)

        let prompt = """
        You are DiskSage's read-only cleanup advisor. Review only the candidate metadata below.
        Do not inspect the filesystem, run tools, or suggest paths that are not listed. The host app,
        not you, controls deletion. Prefer deleting regenerable caches and builds. Treat archives and
        simulator data as review-only unless there is an unusually strong reason.

        Return only JSON with this exact shape:
        {"summary":"short summary","recommendations":[{"id":"UUID","decision":"delete|keep|review","rationale":"short reason"}]}

        Include every candidate exactly once and preserve its ID.

        Candidates:
        \(json)
        """

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
        process.standardError = stderrHandle
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        controller.set(process)
        try process.run()
        if completion.wait(timeout: .now() + 90) == .timedOut {
            controller.terminate()
            if completion.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            stderrHandle.closeFile()
            controller.clear()
            throw CodexAdvisorError.timedOut
        }
        stderrHandle.closeFile()
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
        let ids = response.recommendations.map(\.id)
        guard response.summary.utf8.count <= 1_000,
              response.recommendations.count == expectedIDs.count,
              Set(ids).count == ids.count,
              Set(ids) == expectedIDs,
              response.recommendations.allSatisfy({ $0.rationale.utf8.count <= 500 }) else {
            throw CodexAdvisorError.invalidResponse
        }
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

    private static let responseSchema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["summary", "recommendations"],
      "properties": {
        "summary": {"type": "string", "maxLength": 1000},
        "recommendations": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "decision", "rationale"],
            "properties": {
              "id": {"type": "string", "format": "uuid"},
              "decision": {"type": "string", "enum": ["delete", "keep", "review"]},
              "rationale": {"type": "string", "maxLength": 500}
            }
          }
        }
      }
    }
    """

    private func stripMarkdownFences(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }
}
