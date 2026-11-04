import Foundation
import Testing
@testable import DiskSage

struct OllamaAdvisorTests {
    @Test func discoversLocalAndCloudModelsAndFiltersEmbeddingOnlyModels() async throws {
        let advisor = OllamaAdvisor { request in
            #expect(request.url?.host == "127.0.0.1")
            #expect(request.url?.path == "/api/tags")
            return Data("""
            {"models":[{"name":"local","capabilities":["completion"]},
            {"name":"remote:cloud","remote_host":"https://ollama.com","capabilities":["completion"]},
            {"name":"embedding","capabilities":["embedding"]}]}
            """.utf8)
        }
        let models = try await advisor.availableModels()
        #expect(models.map(\.name) == ["local", "remote:cloud"])
        #expect(models.map(\.isCloud) == [false, true])
    }

    @Test(arguments: [false, true])
    func cloudRequestsUsePromptedJSONWhileLocalRequestsUseSchema(cloud: Bool) throws {
        let model = OllamaModel(name: cloud ? "test:cloud" : "test:latest")
        let request = try OllamaAdvisor().generationRequest(candidates: [fixture()], model: model)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/chat")
        #expect(body["stream"] as? Bool == false)
        #expect((body["format"] != nil) == !cloud)
        #expect(body["tools"] == nil)
    }

    @Test func validatesGenerationAndRefusesUnknownModel() async throws {
        let candidate = fixture()
        let advisor = OllamaAdvisor { request in
            if request.url?.path == "/api/tags" { return Data("{\"models\":[{\"name\":\"local\"}]}".utf8) }
            let response: [String: Any] = ["done": true, "message": ["content": "{\"summary\":\"Done\",\"recommendations\":[{\"id\":\"\(candidate.id)\",\"decision\":\"review\",\"rationale\":\"Review\"}]}"]]
            return try JSONSerialization.data(withJSONObject: response)
        }
        let response = try await advisor.recommend(candidates: [candidate], model: "local")
        #expect(response.recommendations.first?.id == candidate.id)
        await #expect(throws: AdvisorError.self) { try await advisor.recommend(candidates: [candidate], model: "missing") }
    }

    @Test func incompleteResponsesCannotChangeSelection() async {
        let advisor = OllamaAdvisor { request in
            if request.url?.path == "/api/tags" { return Data("{\"models\":[{\"name\":\"local\"}]}".utf8) }
            return Data("{\"done\":false,\"message\":{\"content\":\"{}\"}}".utf8)
        }
        await #expect(throws: AdvisorError.self) { try await advisor.recommend(candidates: [fixture()], model: "local") }
    }

    @Test(arguments: ["http", "connection", "timeout", "cancelled"])
    func generationTransportErrorsKeepTheirMeaning(failure: String) async {
        let expected: any Error
        switch failure {
        case "http": expected = AdvisorError.failed("Ollama request failed (HTTP 410). Choose another model.")
        case "connection": expected = AdvisorError.unavailable("Could not reach Ollama.")
        case "timeout": expected = AdvisorError.timedOut
        default: expected = CancellationError()
        }
        let advisor = OllamaAdvisor { request in
            if request.url?.path == "/api/tags" { return Data(#"{"models":[{"name":"local"}]}"#.utf8) }
            throw expected
        }
        do { _ = try await advisor.recommend(candidates: [fixture()], model: "local"); Issue.record("Expected transport failure") }
        catch {
            if failure == "cancelled" { #expect(error is CancellationError) }
            else { #expect(error.localizedDescription == expected.localizedDescription) }
        }
    }

    @Test(arguments: [401, 403, 404, 410, 429, 500])
    func httpFailuresIncludeStatusAndRecoveryWithoutRawProviderData(status: Int) throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "http://127.0.0.1:11434/api/chat")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        let raw = Data(#"{"error":"private path /Users/private token=secret-value"}"#.utf8)
        do { _ = try OllamaAdvisor.validateResponse(raw, response: response); Issue.record("Expected HTTP failure") }
        catch {
            #expect(error.localizedDescription.contains("HTTP \(status)"))
            #expect(!error.localizedDescription.contains("secret-value"))
            #expect(!error.localizedDescription.contains("/Users/private"))
            if status == 410 { #expect(error.localizedDescription.contains("Refresh models in Settings")) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSAGE_LIVE_OLLAMA_MODEL"] != nil))
    func ollamaCompletesRealSyntheticReview() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["DISKSAGE_LIVE_OLLAMA_MODEL"])
        let candidate = fixture()
        let response = try await OllamaAdvisor().recommend(candidates: [candidate], model: model, allowsCleanupRequests: true)
        try AdvisorContract.validate(response, expectedIDs: [candidate.id])
        #expect(response.cleanupRequested != nil)
    }

    private func fixture() -> CleanupCandidate {
        CleanupCandidate(url: URL(fileURLWithPath: "/fixture/build"), name: "fixture", category: .build,
                         size: 4096, risk: .low, reason: "Generated output.")
    }
}
