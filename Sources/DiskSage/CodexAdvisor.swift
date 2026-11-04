import Foundation

enum CodexAdvisorError: LocalizedError {
    case executableNotFound
    case failed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found. Install or sign in to Codex first."
        case let .failed(message):
            "Codex advisor failed: \(message)"
        case .invalidResponse:
            "Codex returned an unreadable recommendation."
        }
    }
}

struct CodexAdvisor: Sendable {
    private struct AdvisorCandidate: Codable {
        let id: UUID
        let name: String
        let category: String
        let sizeBytes: Int64
        let risk: String
        let reason: String
    }

    func recommend(candidates: [CleanupCandidate], executablePath: String, model: String) async throws -> AgentResponse {
        let payload = candidates.map {
            AdvisorCandidate(
                id: $0.id,
                name: $0.name,
                category: $0.category.rawValue,
                sizeBytes: $0.size,
                risk: $0.risk.title,
                reason: $0.reason
            )
        }
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)

        return try await Task.detached(priority: .userInitiated) {
            try runCodex(json: json, executablePath: executablePath, model: model)
        }.value
    }

    private func runCodex(json: String, executablePath: String, model: String) throws -> AgentResponse {
        let executable = URL(fileURLWithPath: executablePath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodexAdvisorError.executableNotFound
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "DiskSage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appending(path: "recommendation.json")

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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CodexAdvisorError.failed("process exited with status \(process.terminationStatus)")
        }
        let responseData = try Data(contentsOf: outputURL)
        let cleaned = stripMarkdownFences(String(decoding: responseData, as: UTF8.self))
        guard let cleanedData = cleaned.data(using: .utf8),
              let response = try? JSONDecoder().decode(AgentResponse.self, from: cleanedData) else {
            throw CodexAdvisorError.invalidResponse
        }
        return response
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
