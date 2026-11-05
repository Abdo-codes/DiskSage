import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

struct MCPRegistrationTests {
    static let path = "/Applications/Abdo's $(touch literal) `echo literal` DiskSage.app/Contents/MacOS/DiskSage"
    static func configured(_ client: MCPClient, path: String = path) -> MCPCommandOutput {
        let text: String
        if client == .codex {
            let data = try! JSONSerialization.data(withJSONObject: ["enabled": true,
                "transport": ["type": "stdio", "command": path, "args": ["--mcp"]]])
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = "Scope: User config (available in all your projects)\nType: stdio\nCommand: \(path)\nArgs: --mcp\n"
        }
        return .init(exitCode: 0, text: text)
    }

    @Test(arguments: MCPClient.allCases)
    func connectChecksForConflictsAddsOnlyMissingEntriesAndVerifiesTheSavedCommand(client: MCPClient) async {
        let calls = LockIsolated<[[String]]>([])
        let service = MCPRegistrationService(resolve: { _ in URL(fileURLWithPath: "/fixture/client") }, run: { _, args in
            let count = calls.withValue { $0.append(args); return $0.count }
            if count == 1 { return .init(exitCode: 1, text: "No MCP server named 'disksage' found.") }
            if count == 2 { return .init(exitCode: 0, text: "Added") }
            return Self.configured(client)
        })
        #expect(await service.perform(client: client, path: Self.path, connect: true) == .configured)
        #expect(calls.value == [client.readArguments, client.addArguments(path: Self.path), client.readArguments])
        // Repeated clicks are idempotent and never rewrite a configured entry.
        #expect(await service.perform(client: client, path: Self.path, connect: true) == .configured)
        #expect(calls.value.count == 4 && calls.value.last == client.readArguments)
    }

    @Test(arguments: MCPClient.allCases, [false, true])
    func existingEntriesArePreservedIncludingCustomPaths(client: MCPClient, custom: Bool) async {
        let calls = LockIsolated<[[String]]>([])
        let service = MCPRegistrationService(resolve: { _ in URL(fileURLWithPath: "/fixture/client") }, run: { _, args in
            calls.withValue { $0.append(args) }
            return Self.configured(client, path: custom ? "/another/server" : Self.path)
        })
        let result = await service.perform(client: client, path: Self.path, connect: true)
        #expect(result == (custom ? .conflict : .configured))
        #expect(calls.value == [client.readArguments])
    }

    @Test(arguments: MCPClient.allCases)
    func unreadableConfigurationIsNeverTreatedAsAnAbsentEntry(client: MCPClient) async {
        let calls = LockIsolated(0)
        let service = MCPRegistrationService(resolve: { _ in URL(fileURLWithPath: "/fixture/client") }, run: { _, _ in
            calls.withValue { $0 += 1 }; return .init(exitCode: 1, text: "Permission denied")
        })
        if case .failed = await service.perform(client: client, path: Self.path, connect: true) {} else { Issue.record("Expected a read failure") }
        #expect(calls.value == 1)
    }

    @Test func missingCliAndFailedWritesCannotReportConfigurationSuccess() async {
        let missing = MCPRegistrationService(resolve: { _ in nil }, run: { _, _ in Issue.record("Must not launch a process"); return .init(exitCode: 0, text: "") })
        #expect(await missing.perform(client: .codex, path: Self.path, connect: true) == .notInstalled)
        for failWrite in [true, false] {
            let calls = LockIsolated(0)
            let service = MCPRegistrationService(resolve: { _ in URL(fileURLWithPath: "/fixture/client") }, run: { _, args in
                calls.withValue { $0 += 1 }
                if args.contains("add") { return .init(exitCode: failWrite ? 1 : 0, text: "") }
                return .init(exitCode: 1, text: "No MCP server named disksage")
            })
            if case .failed = await service.perform(client: .codex, path: Self.path, connect: true) {} else { Issue.record("Expected a setup failure") }
            #expect(calls.value == (failWrite ? 2 : 3))
        }
    }

    @Test func runnerUsesLiteralArgumentsAndTerminatesTimedOutClients() throws {
        let output = try MCPCommandRunner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [Self.path])
        #expect(output.exitCode == 0 && output.text == Self.path + "\n")
        #expect(throws: FeatureFailure.self) {
            try MCPCommandRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.02)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSAGE_TEST_MCP_REGISTRATION"] == "1"))
    func installedClientsRegisterAndVerifyInsideDisposableConfigurationDirectories() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DiskSage-MCP-Isolated-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for client in MCPClient.allCases {
            let executable = try #require(client == .claude ? ClaudeAdvisor.discoverExecutable() : CodexAdvisor.discoverExecutable())
            var environment = ProcessInfo.processInfo.environment
            environment[client == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"] = directory.path
            let isolated = environment
            let service = MCPRegistrationService(resolve: { _ in executable }, run: {
                try MCPCommandRunner.run(executable: $0, arguments: $1, environment: isolated)
            })
            let path = "/Applications/DiskSage.app/Contents/MacOS/DiskSage"
            #expect(await service.perform(client: client, path: path, connect: false) == .notConfigured)
            #expect(await service.perform(client: client, path: path, connect: true) == .configured)
            #expect(await service.perform(client: client, path: "/another/server", connect: true) == .conflict)
            #expect(await service.perform(client: client, path: path, connect: false) == .configured)
        }
    }
}

@MainActor
struct MCPIntegrationFeatureTests {
    @Test func checksAreReadOnlyAndRepeatedConnectCannotStartAnotherWrite() async {
        let clock = TestClock()
        let calls = LockIsolated<[Bool]>([])
        let store = TestStore(initialState: MCPIntegrationFeature.State()) { MCPIntegrationFeature() } withDependencies: {
            $0.mcpRegistration.perform = { client, path, connect in
                #expect(client == .claude && path == "/app")
                calls.withValue { $0.append(connect) }
                try? await clock.sleep(for: .seconds(1))
                return connect ? .configured : .notConfigured
            }
        }
        await store.send(.connect(.claude, "/app")) // Unchecked state cannot write.
        await store.send(.check(.claude, "/app")) { $0.busy = [.claude] }
        await clock.advance(by: .seconds(1))
        await store.receive(.finished(.claude, .notConfigured)) { $0.busy = []; $0.statuses[.claude] = .notConfigured }
        await store.send(.connect(.claude, "/app")) { $0.busy = [.claude] }
        await store.send(.connect(.claude, "/app"))
        await clock.advance(by: .seconds(1))
        await store.receive(.finished(.claude, .configured)) { $0.busy = []; $0.statuses[.claude] = .configured }
        await store.send(.connect(.claude, "/app")) // Configured state cannot rewrite.
        #expect(calls.value == [false, true])
        await store.finish()
    }
}
