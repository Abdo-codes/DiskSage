import Foundation
import CoreFoundation

/// This registry is shared by discovery and validation. Unknown keys never reach the app.
enum MCPManagementSchema {
    struct Definition {
        let name: String
        let description: String
        var properties: [String: [String: Any]] = [:]
        var required: [String] = []
        var readOnly = false
        var destructive = false
        var requestID = false
        var schema: [String: Any] {
            var properties = properties, required = required
            if requestID { properties["request_id"] = MCPManagementSchema.uuid; required.append("request_id") }
            return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive,
                    "idempotentHint": requestID || readOnly, "openWorldHint": name == "request_advice" || name == "list_models"]]
        }
    }
    static let uuid: [String: Any] = ["type": "string", "format": "uuid"]
    static let text: [String: Any] = ["type": "string", "maxLength": 4_096]
    static let boolean: [String: Any] = ["type": "boolean"]
    static func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    static func integer(_ low: Int, _ high: Int) -> [String: Any] { ["type": "integer", "minimum": low, "maximum": high] }
    static let ids: [String: Any] = ["type": "array", "items": uuid, "maxItems": 100, "uniqueItems": true]
    static var page: [String: [String: Any]] { ["offset": integer(0, Int.max), "limit": integer(1, 100)] }
    static var timing: [String: [String: Any]] {
        ["frequency": choice(["daily", "weekly", "once"]), "hour": integer(0, 23), "minute": integer(0, 59),
         "weekday": integer(1, 7), "run_at": ["type": "string", "format": "date-time"], "enabled": boolean,
         "target": choice(["xcode_derived_data", "bazel_cache", "npm_cache", "folder"]), "path": text,
         "scope": choice(["lowRisk", "folderContents"])]
    }
    static var definitions: [Definition] {
        [Definition(name: "get_dashboard", description: "Read disk usage, operation ID/progress, selection, errors, recommendations, and pending confirmations. Snapshots include their scan time.", readOnly: true),
         Definition(name: "list_candidates", description: "Review scanned candidates, paths, risk and deletion scope. Scan first for fresh IDs. This does not share paths with built-in advisors.",
            properties: page.merging(["query": text, "risk": choice(["all", "low", "medium", "high"])]) { $1 }, readOnly: true),
         Definition(name: "set_selection", description: "Replace, add or remove candidate IDs from the app's selection. Empty replace clears all. Busy operations reject changes.",
            properties: ["candidate_ids": ids, "mode": choice(["replace", "add", "remove"])], required: ["candidate_ids", "mode"], requestID: true),
         Definition(name: "delete_candidates", description: "Request deletion of scanned candidate IDs, including sensitive items. ALWAYS requires a person to confirm the exact paths in DiskSage. Poll get_job; never claim deletion from acceptance.",
            properties: ["candidate_ids": ids], required: ["candidate_ids"], destructive: true, requestID: true),
         Definition(name: "cancel_operation", description: "Cancel the matching scan/advisor or queued worktree removals. A running deletion always finishes. Read operation_id from get_dashboard.",
            properties: ["operation_id": uuid], required: ["operation_id"], requestID: true),
         Definition(name: "dismiss_confirmation", description: "Cancel a pending deletion or management approval. Cannot approve any request. Read confirmation_id from get_dashboard.",
            properties: ["confirmation_id": uuid], required: ["confirmation_id"], requestID: true),
         Definition(name: "list_schedules", description: "Read saved schedules, paths, revisions, time zone, next runs and last results. Follow next_offset until null. Existing folders only; use revisions when editing.", properties: page, readOnly: true),
         Definition(name: "create_schedule", description: "Register a daily/weekly/once folder schedule. Recurring requires hour and minute; weekly also weekday (Sunday=1); once requires run_at with UTC offset. Presets resolve on this Mac. All-contents scope requires in-app authorization. Confirm policy saves low-risk schedules paused. UUID retries persist across restart for the last 200 mutations.",
            properties: timing, required: ["target", "frequency"], destructive: true, requestID: true),
         Definition(name: "update_schedule", description: "Patch a saved schedule using its latest revision. Changing frequency requires complete timing fields. Other fields are preserved. All-contents changes require in-app authorization; confirm policy pauses low-risk changes until enabled in the app.",
            properties: timing.merging(["schedule_id": uuid, "expected_revision": integer(0, Int.max)]) { $1 },
            required: ["schedule_id", "expected_revision"], destructive: true, requestID: true),
         Definition(name: "pause_schedule", description: "Pause future runs using the latest revision. A deletion already started finishes. To resume, update_schedule with enabled=true.",
            properties: ["schedule_id": uuid, "expected_revision": integer(0, Int.max)], required: ["schedule_id", "expected_revision"], requestID: true),
         Definition(name: "remove_schedule", description: "Remove a schedule using its latest revision. Does not delete folder contents. Already-started deletion finishes.",
            properties: ["schedule_id": uuid, "expected_revision": integer(0, Int.max)], required: ["schedule_id", "expected_revision"], destructive: true, requestID: true),
         Definition(name: "get_settings", description: "Read current app settings and advisor configuration. No credentials are returned. Also includes launch-at-login status.", readOnly: true),
         Definition(name: "update_settings", description: "Request an app-settings patch. ALWAYS requires explicit in-app approval, including cleanup policy, metadata consent and executable paths. Agents cannot approve or grant themselves access. Poll get_job.",
            properties: ["settings": ["type": "object", "properties": ToolSettings.schema, "additionalProperties": false]],
            required: ["settings"], destructive: true, requestID: true),
         Definition(name: "list_advisors", description: "Read provider configuration, metadata consent and local readiness. CLI presence does not verify sign-in or quota.", readOnly: true),
         Definition(name: "list_models", description: "List model choices; Ollama queries localhost and may fail. Returns a job; poll get_job for result. Never downloads models.",
            properties: ["provider": choice(["codex", "claude", "apple", "ollama"])], required: ["provider"], readOnly: true, requestID: true),
         Definition(name: "request_advice", description: "Run the configured advisor on scanned metadata. Missing provider consent requires in-app approval. Honors the app's built-in cleanup-request setting. Returns a job; poll get_job and get_dashboard for recommendations.",
            properties: ["provider": choice(["codex", "claude", "apple", "ollama"])], required: ["provider"], destructive: true, requestID: true),
         Definition(name: "get_history", description: "Read completed cleanup runs and item results. Returns a job; poll get_job. Logs are local and rotated, so older details may no longer exist.",
            properties: page, readOnly: true, requestID: true),
         Definition(name: "get_logs", description: "Read the newest bounded cleanup log events, optionally for a run UUID. Returns a job; poll get_job. An item start alone never proves deletion.",
            properties: ["limit": integer(1, 200), "offset": integer(0, Int.max), "run_id": uuid], readOnly: true, requestID: true),
         Definition(name: "get_mcp_setup", description: "Read the same Claude Code and Codex connection commands shown in Settings.", readOnly: true),
         Definition(name: "open_window", description: "Open/focus a native DiskSage screen or its log folder.",
            properties: ["window": choice(["dashboard", "review", "worktrees", "settings", "schedules", "history", "logs", "agent", "tools", "mcp", "general", "about", "onboarding"])], required: ["window"], requestID: true),
         Definition(name: "reveal_candidate", description: "Reveal one current scanned candidate in Finder; arbitrary paths are not accepted.",
            properties: ["candidate_id": uuid], required: ["candidate_id"], requestID: true),
         Definition(name: "quit_app", description: "Request DiskSage to quit. Refused while deletion is running. MCP becomes unavailable until the app is reopened; stopping the app stops schedule checks.", requestID: true)] + MCPWorktreeSchema.definitions
    }

    static func command(name: String, arguments: [String: Any]) throws -> AgentToolRequest? {
        guard let definition = definitions.first(where: { $0.name == name }) else { return nil }
        try validate(arguments, schema: definition.schema["inputSchema"] as! [String: Any])
        let values = try JSONDecoder().decode([String: ToolValue].self, from: JSONSerialization.data(withJSONObject: arguments))
        let id = values["request_id"]?.string.flatMap(UUID.init(uuidString:))
        return AgentToolRequest(action: .manage, requestID: id, tool: name, arguments: values)
    }

    static func validate(_ value: Any, schema: [String: Any]) throws {
        func invalid() -> MCPServer.MCPError { .init(message: "Invalid tool arguments. Use the tool's input schema; unknown fields and permission overrides are rejected.") }
        switch schema["type"] as? String {
        case "object":
            guard let value = value as? [String: Any] else { throw invalid() }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            guard Set(value.keys).isSubset(of: Set(properties.keys)),
                  Set(schema["required"] as? [String] ?? []).isSubset(of: Set(value.keys)) else { throw invalid() }
            for (key, item) in value { try validate(item, schema: properties[key]!) }
        case "array":
            guard let value = value as? [Any], value.count <= (schema["maxItems"] as? Int ?? 100),
                  let item = schema["items"] as? [String: Any] else { throw invalid() }
            for value in value { try validate(value, schema: item) }
            if schema["uniqueItems"] as? Bool == true {
                let encoded = try value.map { try JSONSerialization.data(withJSONObject: [$0], options: [.sortedKeys]) }
                guard Set(encoded).count == encoded.count else { throw invalid() }
            }
        case "string":
            guard let value = value as? String, value.count <= (schema["maxLength"] as? Int ?? 4_096) else { throw invalid() }
            if let choices = schema["enum"] as? [String], !choices.contains(value) { throw invalid() }
            if schema["format"] as? String == "uuid", UUID(uuidString: value) == nil { throw invalid() }
            if schema["format"] as? String == "date-time", parseDate(value) == nil { throw invalid() }
        case "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(schema["minimum"] as? Int ?? Int.min),
                  number.doubleValue <= Double(schema["maximum"] as? Int ?? Int.max) else { throw invalid() }
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid() }
        default: throw invalid()
        }
    }
    static func parseDate(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: value) { return date }
        parser.formatOptions.insert(.withFractionalSeconds)
        return parser.date(from: value)
    }
}
