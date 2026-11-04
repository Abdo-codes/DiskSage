import Foundation

enum AgentProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, apple, ollama
    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .apple: "Apple on-device"
        case .ollama: "Ollama"
        }
    }
    var consentKey: String? {
        switch self {
        case .codex: "agentMetadataConsent"
        case .claude: "claudeMetadataConsent"
        case .apple: nil
        case .ollama: "ollamaMetadataConsent"
        }
    }
}

struct AgentConfiguration: Equatable, Sendable {
    let provider: AgentProvider
    var executablePath = ""
    var model = ""
    var allowsCleanupRequests = false
}

typealias AdvisorAction = @Sendable ([CleanupCandidate], AgentConfiguration) async throws -> AgentResponse

enum AdvisorError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason), let .failed(reason): reason
        case .invalidResponse: "The agent returned an invalid recommendation. No selection was changed."
        case .timedOut: "The agent did not respond within 90 seconds. Try fewer items or a different agent."
        }
    }
}

struct AgentAdvisor: Sendable {
    func recommend(candidates: [CleanupCandidate], configuration: AgentConfiguration) async throws -> AgentResponse {
        let response: AgentResponse
        switch configuration.provider {
        case .codex:
            response = try await CodexAdvisor().recommend(candidates: candidates,
                executablePath: configuration.executablePath, model: configuration.model, allowsCleanupRequests: configuration.allowsCleanupRequests)
        case .claude:
            response = try await ClaudeAdvisor().recommend(candidates: candidates,
                executablePath: configuration.executablePath, model: configuration.model, allowsCleanupRequests: configuration.allowsCleanupRequests)
        case .apple, .ollama:
            response = try await withThrowingTaskGroup(of: AgentResponse.self) { group in
                group.addTask {
                    if configuration.provider == .apple { return try await AppleAdvisor().recommend(candidates: candidates, allowsCleanupRequests: configuration.allowsCleanupRequests) }
                    return try await OllamaAdvisor().recommend(candidates: candidates, model: configuration.model, allowsCleanupRequests: configuration.allowsCleanupRequests)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(90))
                    throw AdvisorError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        try Task.checkCancellation()
        try AdvisorContract.validate(response, expectedIDs: Set(candidates.map(\.id)))
        return response
    }
}
