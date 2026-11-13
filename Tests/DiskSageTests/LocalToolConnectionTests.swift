import ComposableArchitecture
import Darwin
import Foundation
import Testing
@testable import DiskSage

struct LocalToolConnectionTests {
    @Test func socketRoundTripIsSameUserPrivateAndSingleOwner() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/disksage-tool-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try AgentToolServer(directory: root) { request in
            AgentToolReply(error: request.action == .status ? "fixture" : "unexpected")
        }
        let task = Task.detached { await server.serve() }
        let path = root.appending(path: "control.sock").path
        do {
            let reply = try await onSocketQueue {
                try LocalToolConnection.call(AgentToolRequest(action: .status), path: path)
            }
            #expect(reply.error == "fixture")
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(throws: (any Error).self) { try AgentToolServer(directory: root) { _ in AgentToolReply() } }
        } catch {
            task.cancel()
            await task.value
            throw error
        }
        task.cancel()
        await task.value
    }

    @MainActor @Test func mcpRequestDeletesOnlyAnAllowlistedFixtureAndLogsAgentTrigger() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer/.disksage-tool-e2e-\(UUID())")
        let socketRoot = URL(fileURLWithPath: "/private/tmp/disksage-mcp-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketRoot)
        }
        let target = root.appending(path: ".build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: target.appending(path: "artifact"))
        let candidate = try #require(DiskScanner.inspect(target, name: "Fixture", category: .build, risk: .low, reason: "Fixture"))
        let logger = CleanupLogger(directory: root.appending(path: "logs"))
        let store = Store(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date = .constant(FeatureTestSupport.epoch)
            $0.diskSage = .testValue
            $0.diskSage.scan = { ScanReport(candidates: [candidate]) }
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.diskSage.cleanup = { targets, trigger, progress in
                await CleanupService(logger: logger).delete(targets, trigger: trigger, progress: progress)
            }
        }
        let model = AppModel(store: store)
        let id = UUID()
        let completions = AsyncStream<AgentToolJob>.makeStream()
        let observation = observe {
            if let job = store.agentToolJobs[id], job.phase.isTerminal {
                completions.continuation.yield(job)
                completions.continuation.finish()
            }
        }
        defer { observation.cancel() }
        let server = try AgentToolServer(directory: socketRoot) { model.handleAgentToolRequest($0) }
        let serving = Task.detached { await server.serve() }
        do {
            let path = socketRoot.appending(path: "control.sock").path
            let accepted = try await onSocketQueue {
                let mcp = MCPServer { try LocalToolConnection.call($0, path: path) }
                let initialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8)
                _ = mcp.respond(to: initialize)
                let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2,
                    "method": "tools/call", "params": ["name": "clean_low_risk", "arguments": ["request_id": id.uuidString]]])
                return try #require(mcp.respond(to: request))
            }
            let response = try #require(JSONSerialization.jsonObject(with: accepted) as? [String: Any])
            #expect((response["result"] as? [String: Any])?["isError"] as? Bool == false)
            let completed = await completions.stream.first { _ in true }
            #expect(completed?.phase == .succeeded)
            let finished = try await onSocketQueue {
                try LocalToolConnection.call(.init(action: .job, requestID: id), path: path)
            }
            #expect(finished.job?.phase == .succeeded && finished.job?.deletedCount == 1)
            #expect(!FileManager.default.fileExists(atPath: target.path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let events = try Data(contentsOf: logger.fileURL).split(separator: 0x0A).map {
                try decoder.decode(CleanupLogEvent.self, from: Data($0))
            }
            #expect(events.map(\.event) == [.started, .itemStarted, .itemFinished, .finished])
            #expect(events.allSatisfy { $0.trigger == .agent })
            #expect(events[2].succeeded == true && events[2].path == target.path)
        } catch {
            serving.cancel()
            await serving.value
            throw error
        }
        serving.cancel()
        await serving.value
    }

    @Test func refusesSymlinkEndpointAndUnavailableApp() throws {
        let root = URL(fileURLWithPath: "/private/tmp/disksage-tool-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let endpoint = root.appending(path: "control.sock")
        try FileManager.default.createSymbolicLink(atPath: endpoint.path, withDestinationPath: "/tmp/nonexistent")
        #expect(throws: (any Error).self) { try AgentToolServer(directory: root) { _ in AgentToolReply() } }
        #expect(throws: (any Error).self) { try LocalToolConnection.call(.init(action: .status), path: "/tmp/disksage-missing-\(UUID())") }
        #expect(throws: (any Error).self) { try LocalToolConnection.address(String(repeating: "x", count: 104)) }
    }
}

private func onSocketQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
    }
}
