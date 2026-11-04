import Foundation
import Testing
@testable import DiskSage

struct AgentReadinessTests {
    @Test(arguments: [AgentProvider.claude, .codex])
    func missingCLIIsExplainedAndConfiguredPathIsChecked(provider: AgentProvider) async {
        let configuration = AgentConfiguration(provider: provider, executablePath: "/custom/cli")
        var client = AgentReadinessClient()
        client.executableFound = { #expect($0 == configuration); return false }
        let unavailable = await client.check(configuration)
        #expect(!unavailable.isReady)
        guard case let .unavailable(reason) = unavailable else { Issue.record("Missing explanation"); return }
        #expect(reason.contains(provider.title) && reason.contains("Agent Settings"))
        client.executableFound = { _ in true }
        #expect(await client.check(configuration) == .ready)
    }

    @Test func nativeAvailabilityPreservesSystemExplanation() async {
        var client = AgentReadinessClient()
        client.appleUnavailableReason = { "Model still downloading" }
        #expect(await client.check(.init(provider: .apple)) == .unavailable("Model still downloading"))
        client.appleUnavailableReason = { nil }
        #expect(await client.check(.init(provider: .apple)) == .ready)
    }

    @Test func ollamaRequiresASelectedAndAvailableTextModel() async {
        var client = AgentReadinessClient()
        client.ollamaModels = { Issue.record("An empty model must not make a request"); return [] }
        #expect(!(await client.check(.init(provider: .ollama))).isReady)
        client.ollamaModels = { [OllamaModel(name: "local:latest")] }
        #expect(await client.check(.init(provider: .ollama, model: "local:latest")) == .ready)
        #expect(!(await client.check(.init(provider: .ollama, model: "missing"))).isReady)
        client.ollamaModels = { throw URLError(.cannotConnectToHost) }
        #expect(await client.check(.init(provider: .ollama, model: "local:latest")) ==
            .unavailable("Ollama is not reachable. Start Ollama, then check the model in Agent Settings."))
    }
}
