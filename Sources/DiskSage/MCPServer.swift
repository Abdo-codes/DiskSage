import Foundation

/// MCP stdio mode is a bridge to the one running GUI coordinator.
final class MCPServer {
    typealias ToolCall = (AgentToolRequest) throws -> AgentToolReply
    private let call: ToolCall
    private var initialized = false

    init(call: @escaping ToolCall = { try LocalToolConnection.call($0) }) { self.call = call }

    func run() {
        // stdout is reserved exclusively for newline-delimited JSON-RPC.
        while let frame = try? LocalToolConnection.readFrame(STDIN_FILENO) {
            if let reply = respond(to: frame) { try? LocalToolConnection.writeFrame(reply, to: STDOUT_FILENO) }
        }
    }

    func respond(to data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let request = object as? [String: Any] else {
            return encode(error(-32700, "Invalid JSON-RPC message.", id: NSNull()))
        }
        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return encode(error(-32600, "Invalid JSON-RPC request.", id: id))
        }
        // Notifications, including notifications/initialized and cancellation, have no reply.
        // Cleanup belongs to the GUI and survives client disconnection or cancellation.
        guard request["id"] != nil else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        if method == "initialize" {
            let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]
            let requested = params["protocolVersion"] as? String ?? ""
            initialized = true
            return encode(result([
                "protocolVersion": versions.contains(requested) ? requested : versions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "DiskSage", "version": "0.2.0"],
                "instructions": "Open DiskSage first. Start scan or cleanup with a new UUID request_id, then poll get_job. Reuse the same UUID only to retry the same request. Only low-risk generated files can be cleaned. Confirmation depends on DiskSage Settings."
            ], id: id))
        }
        if method == "ping" { return encode(result([:], id: id)) }
        guard initialized else { return encode(error(-32000, "Initialize the MCP session first.", id: id)) }
        switch method {
        case "tools/list": return encode(result(["tools": Self.tools], id: id))
        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(error(-32602, "A tool name is required.", id: id))
            }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return encode(error(-32602, "arguments must be an object.", id: id))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let command = try Self.command(name: name, arguments: arguments)
                let reply = try call(command)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let value = String(decoding: try encoder.encode(reply), as: UTF8.self)
                return encode(result(["content": [["type": "text", "text": value]], "isError": reply.error != nil], id: id))
            } catch let failure as MCPError {
                return encode(error(-32602, failure.message, id: id))
            } catch {
                let message = (error as? LocalToolConnection.ConnectionError)?.errorDescription ?? "DiskSage tool connection failed."
                return encode(result(["content": [["type": "text", "text": message]], "isError": true], id: id))
            }
        default: return encode(error(-32601, "Method not found.", id: id))
        }
    }

    struct MCPError: Error { let message: String }

    static func command(name: String, arguments: [String: Any]) throws -> AgentToolRequest {
        let action: AgentToolRequest.Action
        switch name {
        case "get_status": action = .status
        case "scan": action = .scan
        case "clean_low_risk": action = .cleanLowRisk
        case "get_job": action = .job
        default: throw MCPError(message: "Unknown DiskSage tool.")
        }
        let expected: Set<String> = action == .status ? [] : ["request_id"]
        guard Set(arguments.keys) == expected else { throw MCPError(message: "Invalid arguments. Paths and risk overrides are not accepted.") }
        if action == .status { return AgentToolRequest(action: action) }
        guard let raw = arguments["request_id"] as? String, let id = UUID(uuidString: raw) else {
            throw MCPError(message: "request_id must be a UUID string.")
        }
        return AgentToolRequest(action: action, requestID: id)
    }

    static var tools: [[String: Any]] {
        [tool("get_status", description: "Read free disk space, aggregate candidates, busy state and agent cleanup policy.", action: .status),
         tool("scan", description: "Start a fresh scan. Returns a job; poll get_job. UUID request_id deduplicates retries during this app session.", action: .scan),
         tool("clean_low_risk", description: "Scan, then request cleanup of low-risk generated files only. May await confirmation in DiskSage. Returns a job; poll get_job for the actual result. Permanent deletion. No paths or risk overrides accepted.", action: .cleanLowRisk),
         tool("get_job", description: "Read progress or completion by request_id. Unknown means no retained record, never proof of cleanup. The last 100 jobs are retained only until DiskSage quits.", action: .job)]
    }

    private static func tool(_ name: String, description: String, action: AgentToolRequest.Action) -> [String: Any] {
        let properties: [String: Any] = action == .status ? [:] : ["request_id": ["type": "string", "format": "uuid"]]
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties,
                                "required": action == .status ? [] : ["request_id"], "additionalProperties": false],
                "annotations": ["readOnlyHint": action == .status || action == .job,
                                "destructiveHint": action == .cleanLowRisk, "openWorldHint": false]]
    }

    private func result(_ value: [String: Any], id: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
    private func error(_ code: Int, _ message: String, id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    private func encode(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
}
