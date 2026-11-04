import Foundation
import Testing
@testable import DiskSage

struct MCPServerTests {
    @Test func initializesListsToolsAndReturnsAggregateData() throws {
        let server = MCPServer { request in
            #expect(request.action == .status)
            return AgentToolReply(status: AgentToolStatus(busy: false, awaitingConfirmation: false,
                freeSpaceBytes: 1234, candidateCount: 2, lowRiskCount: 1, lowRiskBytes: 500,
                lastScanDate: nil, cleanupPolicy: "confirm"))
        }
        #expect(try response(server, method: "tools/list")["error"] != nil)
        let initialized = try response(server, method: "initialize", params: ["protocolVersion": "2025-06-18"])
        let info = try #require(initialized["result"] as? [String: Any])
        #expect(info["protocolVersion"] as? String == "2025-06-18")
        let listed = try response(server, method: "tools/list")
        let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["get_status", "scan", "clean_low_risk", "get_job"])
        let clean = try #require(tools.first { $0["name"] as? String == "clean_low_risk" })
        #expect((clean["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == true)
        let reply = try response(server, method: "tools/call", params: ["name": "get_status", "arguments": [:]])
        let content = try #require((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((payload["status"] as? [String: Any])?["freeSpaceBytes"] as? Int == 1234)
        #expect(server.respond(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
    }

    @Test(arguments: [
        ("clean_low_risk", ["request_id": UUID().uuidString, "path": "/tmp"]),
        ("clean_low_risk", ["request_id": "invalid"]),
        ("get_status", ["path": "/tmp"]),
        ("scan", [:]),
        ("delete", ["request_id": UUID().uuidString])
    ])
    func rejectsUnknownToolsPathsAndInvalidIdentifiers(name: String, arguments: [String: String]) throws {
        let server = MCPServer { _ in Issue.record("Invalid calls must not reach the app"); return AgentToolReply() }
        _ = try response(server, method: "initialize")
        let reply = try response(server, method: "tools/call", params: ["name": name, "arguments": arguments])
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func passesRequestIDsAndHandlesOfflineAppWithoutLeakingErrors() throws {
        let id = UUID()
        let server = MCPServer { request in
            #expect(request == AgentToolRequest(action: .cleanLowRisk, requestID: id))
            throw NSError(domain: "/private/project-name", code: 1)
        }
        _ = try response(server, method: "initialize")
        let reply = try response(server, method: "tools/call", params: ["name": "clean_low_risk", "arguments": ["request_id": id.uuidString]])
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        #expect(!encoded.contains("project-name"))
        let malformed = try #require(server.respond(to: Data("{".utf8)))
        let parsed = try #require(JSONSerialization.jsonObject(with: malformed) as? [String: Any])
        #expect((parsed["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    private func response(_ server: MCPServer, method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let reply = try #require(server.respond(to: data))
        return try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }
}
