import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct ScheduleToolSocketTests {
    @Test func mcpCreatesEditsPausesAndRemovesTheSameSchedulesExposedByTheApp() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer/.disksage-mcp-schedules-\(UUID())")
        let socketRoot = URL(fileURLWithPath: "/private/tmp/disksage-mcp-schedules-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: socketRoot) }
        let folder = root.appending(path: ".build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Do not delete this fixture".utf8).write(to: folder.appending(path: "artifact"))
        let repository = CleanupScheduleRepository(fileURL: root.appending(path: "settings/schedules.json"))
        let store = ManagementTestSupport.store(ManagementTestSupport.initial()) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.management.identity = { try ScheduledFolderPolicy.identity(of: $0) }
            $0.schedules.validate = { try ScheduledFolderPolicy.validate($0) }
            $0.management.receipt = { id in try repository.receipts().first { $0.request.requestID == id } }
            $0.management.save = { try repository.save($0, receipt: $1) }
        }
        let model = AppModel(store: store)
        let server = try AgentToolServer(directory: socketRoot) { model.handleAgentToolRequest($0) }
        let serving = Task.detached { await server.serve() }
        do {
            let socket = socketRoot.appending(path: "control.sock").path
            let id = UUID()
            let created = try await call("create_schedule", ["request_id": id.uuidString, "target": "folder", "path": folder.path,
                "frequency": "daily", "hour": 2, "minute": 0, "enabled": false], socket: socket)
            #expect(created.error == nil && created.job?.phase == .succeeded)
            #expect(model.schedules.count == 1 && model.schedules[0].id == id && !model.schedules[0].isEnabled)
            let changed = try await call("update_schedule", ["request_id": UUID().uuidString, "schedule_id": id.uuidString,
                "expected_revision": 1, "hour": 3], socket: socket)
            #expect(changed.error == nil && model.schedules[0].hour == 3 && model.schedules[0].revision == 2)
            let paused = try await call("pause_schedule", ["request_id": UUID().uuidString, "schedule_id": id.uuidString,
                "expected_revision": 2], socket: socket)
            #expect(paused.error == nil && model.schedules[0].revision == 3)
            let listed = try await call("list_schedules", [:], socket: socket)
            #expect(listed.data?.object?["schedules"]?.array?.count == 1)
            let removed = try await call("remove_schedule", ["request_id": UUID().uuidString, "schedule_id": id.uuidString,
                "expected_revision": 3], socket: socket)
            #expect(removed.error == nil && model.schedules.isEmpty)
            #expect(try repository.load().isEmpty)
            #expect(try repository.receipts().count == 4)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "artifact").path))
        } catch { serving.cancel(); await serving.value; throw error }
        serving.cancel(); await serving.value
    }

    private func call(_ name: String, _ args: [String: Any], socket: String) async throws -> AgentToolReply {
        // Serialize before leaving the main actor; Any dictionaries are not Sendable.
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": name, "arguments": args]])
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let mcp = MCPServer { try LocalToolConnection.call($0, path: socket) }
                    _ = mcp.respond(to: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8))
                    let reply = try #require(mcp.respond(to: data))
                    let object = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
                    let result = try #require(object["result"] as? [String: Any])
                    let structured = try #require(result["structuredContent"])
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let value = try decoder.decode(AgentToolReply.self, from: JSONSerialization.data(withJSONObject: structured))
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
