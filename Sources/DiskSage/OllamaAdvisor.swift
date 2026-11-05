import Foundation

struct OllamaModel: Codable, Identifiable, Sendable {
    let name: String
    var remote_host: String?
    var capabilities: [String]?
    var id: String { name }
    var isCloud: Bool { remote_host?.isEmpty == false || name.hasSuffix(":cloud") || name.hasSuffix("-cloud") }
    var title: String { "\(name) · \(isCloud ? "Cloud" : "Local")" }
}

struct OllamaAdvisor: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> Data
    var transport: Transport = { request in try await Self.send(request) }
    private let endpoint = URL(string: "http://127.0.0.1:11434")!

    func availableModels() async throws -> [OllamaModel] {
        struct Tags: Decodable { let models: [OllamaModel] }
        let request = URLRequest(url: endpoint.appending(path: "api/tags"), timeoutInterval: 5)
        let models = try JSONDecoder().decode(Tags.self, from: await transport(request)).models
        return models.filter { $0.capabilities == nil || $0.capabilities!.contains("completion") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func recommend(candidates: [CleanupCandidate], model: String, allowsCleanupRequests: Bool = false) async throws -> AgentResponse {
        guard !model.isEmpty else { throw AdvisorError.unavailable("Choose an Ollama model in Settings first.") }
        guard let selected = try await availableModels().first(where: { $0.name == model }) else {
            throw AdvisorError.unavailable("The selected Ollama model is no longer available. Refresh models in Settings.")
        }
        var recommendations: [AgentRecommendation] = []
        var cleanupRequested = false
        for batch in AdvisorContract.batches(candidates) {
            try Task.checkCancellation()
            let request = try generationRequest(candidates: batch, model: selected, allowsCleanupRequests: allowsCleanupRequests)
            struct Reply: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
                let done: Bool
                let done_reason: String?
            }
            let data = try await transport(request)
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  reply.done, reply.done_reason != "length" else {
                throw AdvisorError.invalidResponse
            }
            // A decoding failure on model output gets a clear agent-facing error
            // instead of a raw JSONDecoder stack trace.
            guard let response = try? JSONDecoder().decode(AgentResponse.self, from: Data(reply.message.content.utf8)) else {
                throw AdvisorError.invalidResponse
            }
            try AdvisorContract.validate(response, expectedIDs: Set(batch.map(\.id)))
            recommendations += response.recommendations
            cleanupRequested = cleanupRequested || response.cleanupRequested == true
        }
        return AgentResponse(summary: "Reviewed \(candidates.count) items using Ollama (\(selected.name)).",
                             recommendations: recommendations, cleanupRequested: cleanupRequested)
    }

    func generationRequest(candidates: [CleanupCandidate], model: OllamaModel, allowsCleanupRequests: Bool = false) throws -> URLRequest {
        var payload: [String: Any] = [
            "model": model.name, "stream": false,
            "messages": [
                ["role": "system", "content": AdvisorContract.instructions],
                ["role": "user", "content": AdvisorContract.prompt(metadata: try AdvisorContract.metadataJSON(candidates), allowsCleanupRequests: allowsCleanupRequests)]
            ],
            "options": ["temperature": 0, "num_predict": 1_500, "num_ctx": 8_192]
        ]
        // Cloud models lack Ollama's guided-generation API; their JSON is still strictly validated locally.
        if !model.isCloud {
            payload["format"] = try JSONSerialization.jsonObject(with: Data(AdvisorContract.responseSchema.utf8))
        }
        var request = URLRequest(url: endpoint.appending(path: "api/chat"), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw AdvisorError.timedOut }
        catch { throw AdvisorError.unavailable("Could not reach Ollama at localhost:11434. Start Ollama and try again.") }
        return try validateResponse(data, response: response)
    }

    static func validateResponse(_ data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw AdvisorError.failed("Ollama returned an invalid HTTP response.")
        }
        guard http.statusCode == 200 else {
            let guidance: String
            switch http.statusCode {
            case 401, 403: guidance = "Check your Ollama sign-in or choose a local model."
            case 404, 410: guidance = "Refresh models in Settings or choose another model."
            case 429: guidance = "Check your Ollama usage limit or try again later."
            default: guidance = "Try again or check that Ollama is running."
            }
            throw AdvisorError.failed("Ollama request failed (HTTP \(http.statusCode)). \(guidance)")
        }
        guard data.count <= 2_000_000 else { throw AdvisorError.invalidResponse }
        return data
    }
}
