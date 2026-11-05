import Foundation
import Testing
@testable import DiskSage

struct MCPManagementContractTests {
    @Test func discoveryCoversEveryFunctionalAreaAndStructuredRepliesMatchText() throws {
        let expected: Set<String> = ["get_status", "scan", "clean_low_risk", "get_job", "get_dashboard", "list_candidates",
            "set_selection", "delete_candidates", "cancel_operation", "dismiss_confirmation", "list_schedules",
            "create_schedule", "update_schedule", "pause_schedule", "remove_schedule", "get_settings", "update_settings",
            "list_advisors", "list_models", "request_advice", "get_history", "get_logs", "get_mcp_setup", "open_window",
            "reveal_candidate", "quit_app"]
        #expect(Set(MCPServer.tools.compactMap { $0["name"] as? String }) == expected)
        #expect(MCPServer.tools.count == expected.count)
        let server = MCPServer { _ in AgentToolReply(data: .object(["healthy": .bool(true)])) }
        _ = try response(server, "initialize")
        let reply = try response(server, "tools/call", ["name": "get_dashboard", "arguments": [:]])
        let result = try #require(reply["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content[0]["text"] as? String)
        let fromText = try JSONDecoder().decode(ToolValue.self, from: Data(text.utf8))
        let structured = try JSONDecoder().decode(ToolValue.self, from: JSONSerialization.data(withJSONObject: result["structuredContent"]!))
        #expect(fromText == structured)
        let discovery = try response(server, "tools/list")
        #expect(try JSONSerialization.data(withJSONObject: discovery).count < LocalToolConnection.maximumFrameSize)
    }

    @Test(arguments: [
        ("create_schedule", #"{"request_id":"00000000-0000-0000-0000-000000000001","target":"npm_cache","frequency":"daily","hour":true}"#),
        ("create_schedule", #"{"request_id":"00000000-0000-0000-0000-000000000001","target":"npm_cache","frequency":"daily","hour":2.5}"#),
        ("create_schedule", #"{"request_id":"00000000-0000-0000-0000-000000000001","target":"npm_cache","frequency":"once","run_at":"tomorrow"}"#),
        ("create_schedule", #"{"request_id":"00000000-0000-0000-0000-000000000001","target":"folder","frequency":"daily","force":true}"#),
        ("pause_schedule", #"{"request_id":"00000000-0000-0000-0000-000000000001","schedule_id":"bad","expected_revision":1}"#),
        ("remove_schedule", #"{"request_id":"00000000-0000-0000-0000-000000000001","schedule_id":"00000000-0000-0000-0000-000000000002","expected_revision":-1}"#),
        ("update_settings", #"{"request_id":"00000000-0000-0000-0000-000000000001","settings":{"unknown_permission":true}}"#),
        ("delete_candidates", #"{"request_id":"00000000-0000-0000-0000-000000000001","candidate_ids":[],"confirmed":true}"#),
        ("get_logs", #"{"request_id":"00000000-0000-0000-0000-000000000001","limit":201}"#),
        ("approve_management", #"{"request_id":"00000000-0000-0000-0000-000000000001"}"#)
    ])
    func rejectsMalformedInputAndApprovalBypasses(name: String, json: String) throws {
        let args = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(throws: MCPServer.MCPError.self) { try MCPServer.command(name: name, arguments: args) }
    }

    @Test func pagesRespectByteBudgetWithoutLosingItemsAndOversizedFramesFailExplicitly() throws {
        let items = (0..<100).map { ToolValue.object(["id": .integer($0), "path": .string(String(repeating: "x", count: 2_000))]) }
        var offset = 0, seen: [Int] = []
        while true {
            let result = try ToolPage.make(items, key: "items", offset: offset, limit: 100)
            let page = try #require(result.object)
            let values = try #require(page["items"]?.array)
            seen += values.compactMap { $0.object?["id"]?.integer }
            guard let next = page["next_offset"]?.integer else { break }
            #expect(next > offset); offset = next
        }
        #expect(seen == Array(0..<100))
        let server = MCPServer { _ in AgentToolReply(data: .string(String(repeating: "x", count: 100_000))) }
        _ = try response(server, "initialize")
        let reply = try response(server, "tools/call", ["name": "get_dashboard", "arguments": [:]])
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32603)
    }
    private func response(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let reply = try #require(server.respond(to: data))
        let object = try JSONSerialization.jsonObject(with: reply)
        return try #require(object as? [String: Any])
    }
}
