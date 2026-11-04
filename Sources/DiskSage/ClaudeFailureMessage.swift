import Foundation

/// Classifies structured CLI failures without exposing raw output, paths or account details.
enum ClaudeFailureMessage {
    static func describe(_ data: Data?, exitStatus: Int32? = nil) -> String {
        var details = ""
        if let data, data.count <= 2_000_000,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var fields = ["result", "subtype", "terminal_reason"].compactMap { object[$0] as? String }
            fields += object["errors"] as? [String] ?? []
            if let error = object["error"] as? [String: Any] {
                fields += ["type", "message"].compactMap { error[$0] as? String }
            }
            details = fields.map { String($0.prefix(4_000)) }.joined(separator: " ").lowercased()
        }
        if ["weekly limit", "daily limit", "usage limit", "rate limit", "rate_limit", "quota",
            "hit your limit", "limit reached"].contains(where: details.contains) {
            return "Claude usage limit reached. Wait for the limit to reset or choose another agent."
        }
        if ["credit balance", "out of credits", "billing"].contains(where: details.contains) {
            return "Claude account credits are unavailable. Check your Claude account or choose another agent."
        }
        if ["not logged in", "not authenticated", "authentication", "invalid api key",
            "login required", "token expired"].contains(where: details.contains) {
            return "Claude authentication is missing or expired. Run ‘claude auth login’ in Terminal, then try again."
        }
        if details.contains("error_max_structured_output_retries") {
            return "Claude could not produce valid recommendations. Try another model or agent."
        }
        if details.contains("error_max_turns") {
            return "Claude reached its review turn limit. Try fewer items or another model."
        }
        if let exitStatus {
            return "Claude exited with status \(exitStatus). Check Claude Code for details or choose another agent."
        }
        return "Claude review failed. Check Claude Code for details or choose another agent."
    }
}
