import Foundation

enum AgentReadiness: Equatable, Sendable {
    case ready
    case unavailable(String)
    var isReady: Bool { self == .ready }
}

struct AgentReadinessClient: Sendable {
    var executableFound: @Sendable (AgentConfiguration) -> Bool = { configuration in
        switch configuration.provider {
        case .codex: CodexAdvisor.discoverExecutable(preferredPath: configuration.executablePath) != nil
        case .claude: ClaudeAdvisor.discoverExecutable(preferredPath: configuration.executablePath) != nil
        default: false
        }
    }
    var appleUnavailableReason: @Sendable () -> String? = { AppleAdvisor.unavailableReason }
    var ollamaModels: @Sendable () async throws -> [OllamaModel] = { try await OllamaAdvisor().availableModels() }

    func check(_ configuration: AgentConfiguration) async -> AgentReadiness {
        switch configuration.provider {
        case .codex, .claude:
            return executableFound(configuration) ? .ready
                : .unavailable("\(configuration.provider.title) CLI not found. Install it or set its path in Agent Settings.")
        case .apple:
            return appleUnavailableReason().map(AgentReadiness.unavailable) ?? .ready
        case .ollama:
            guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable("Choose an Ollama model in Agent Settings.")
            }
            do {
                let models = try await ollamaModels()
                return models.contains { $0.name == configuration.model } ? .ready
                    : .unavailable("The selected Ollama model is not available. Choose an installed text model in Agent Settings.")
            } catch {
                return .unavailable("Ollama is not reachable. Start Ollama, then check the model in Agent Settings.")
            }
        }
    }
}
