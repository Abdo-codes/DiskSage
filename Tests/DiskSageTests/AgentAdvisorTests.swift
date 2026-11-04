import Foundation
import Testing
@testable import DiskSage

struct AgentAdvisorTests {
    @Test func metadataExcludesPathsAndNamesAcrossProviders() throws {
        let candidate = fixture()
        let json = try AdvisorContract.metadataJSON([candidate])
        #expect(!json.contains("private-project"))
        #expect(!json.contains("secret-name"))
        let fields = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(Set(fields[0].keys) == ["id", "category", "sizeBytes", "risk", "reason"])
        let request = try OllamaAdvisor().generationRequest(candidates: [candidate], model: OllamaModel(name: "local:latest"))
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(!body.contains("private-project"))
        #expect(!body.contains("secret-name"))
    }

    @Test(arguments: [0, 1, 8, 9, 100])
    func batchesPreserveEveryCandidate(count: Int) {
        let candidates = (0..<count).map { _ in fixture() }
        let batches = AdvisorContract.batches(candidates)
        #expect(batches.allSatisfy { !$0.isEmpty && $0.count <= 8 })
        #expect(batches.flatMap { $0 }.map(\.id) == candidates.map(\.id))
    }

    @Test func nativeIndexMappingPreservesIdentityAndRefusesBadIndices() throws {
        let candidates = [fixture(), fixture()]
        let mapped = try AppleAdvisor.mapAdvice([(1, .review, "Review"), (0, .keep, "Keep")], candidates: candidates)
        #expect(mapped.map(\.id) == candidates.reversed().map(\.id))
        #expect(throws: AdvisorError.self) {
            try AppleAdvisor.mapAdvice([(0, .keep, ""), (0, .keep, "")], candidates: candidates)
        }
        #expect(throws: AdvisorError.self) {
            try AppleAdvisor.mapAdvice([(-1, .keep, ""), (1, .keep, "")], candidates: candidates)
        }
    }

    @Test func claudeArgumentsDisableToolsAndCustomizations() {
        let arguments = ClaudeAdvisor.arguments(prompt: "metadata", model: "sonnet")
        for flag in ["--tools", "--setting-sources"] {
            #expect(arguments[arguments.firstIndex(of: flag)! + 1] == "")
        }
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("mcp__*"))
        #expect(arguments.suffix(2) == ["--", "metadata"])
    }

    @Test(arguments: ["error_max_turns", "error_during_execution", "error_max_structured_output_retries"])
    func claudeRejectsErrorEnvelopes(subtype: String) {
        let data = Data("{\"subtype\":\"\(subtype)\",\"is_error\":true,\"result\":\"failed\"}".utf8)
        #expect(throws: AdvisorError.self) { try ClaudeAdvisor.decode(data) }
    }

    @Test func claudeProcessReturnsValidatedStructuredOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DiskSage-ClaudeTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = fixture()
        let executable = directory.appending(path: "claude")
        let response = "{\"subtype\":\"success\",\"is_error\":false,\"structured_output\":{\"summary\":\"Review complete\",\"recommendations\":[{\"id\":\"\(candidate.id)\",\"decision\":\"keep\",\"rationale\":\"Keep\"}]}}"
        let script = "#!/usr/bin/python3\nimport sys\nassert '--safe-mode' in sys.argv\nprint(\(String(reflecting: response)))\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let result = try await ClaudeAdvisor().recommend(candidates: [candidate], executablePath: executable.path, model: "")
        #expect(result.recommendations.first?.id == candidate.id)
        #expect(result.recommendations.first?.decision == .keep)
    }

    @Test func cancellationBeforeProcessLaunchIsLatched() {
        let controller = AdvisorProcessController()
        controller.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        #expect(throws: CancellationError.self) { try controller.launch(process) }
        #expect(!process.isRunning)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSAGE_LIVE_APPLE_TEST"] == "1"))
    func appleModelCompletesARealBatchedReview() async throws {
        try #require(AppleAdvisor.unavailableReason == nil)
        let candidates = (0..<9).map { _ in fixture() }
        let response = try await AppleAdvisor().recommend(candidates: candidates, allowsCleanupRequests: true)
        try AdvisorContract.validate(response, expectedIDs: Set(candidates.map(\.id)))
        #expect(response.recommendations.count == 9)
        #expect(response.cleanupRequested != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSAGE_LIVE_CLAUDE_TEST"] == "1"))
    func claudeCompletesRealSyntheticReview() async throws {
        let candidate = fixture()
        let response = try await ClaudeAdvisor().recommend(candidates: [candidate], executablePath: "", model: "", allowsCleanupRequests: true)
        try AdvisorContract.validate(response, expectedIDs: [candidate.id])
        #expect(response.cleanupRequested != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSAGE_LIVE_CODEX_TEST"] == "1"))
    func codexCompletesRealSyntheticReview() async throws {
        let candidate = fixture()
        let response = try await CodexAdvisor().recommend(candidates: [candidate], executablePath: "", model: "", allowsCleanupRequests: true)
        try AdvisorContract.validate(response, expectedIDs: [candidate.id])
        #expect(response.cleanupRequested != nil)
    }

    private func fixture() -> CleanupCandidate {
        CleanupCandidate(url: URL(fileURLWithPath: "/private-project/build"), name: "secret-name",
            category: .build, size: 4096, risk: .low, reason: "Generated build output.")
    }
}
