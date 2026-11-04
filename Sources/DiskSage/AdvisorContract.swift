import Foundation

enum AdvisorContract {
    /// Bound prompts for providers with smaller context windows.
    static func batches(_ candidates: [CleanupCandidate]) -> [[CleanupCandidate]] {
        stride(from: 0, to: candidates.count, by: 8).map { Array(candidates[$0..<min($0 + 8, candidates.count)]) }
    }

    private struct Metadata: Encodable {
        let id: UUID
        let category: String
        let sizeBytes: Int64
        let risk: String
        let reason: String
    }

    static func metadataJSON(_ candidates: [CleanupCandidate]) throws -> String {
        let values = candidates.map {
            Metadata(id: $0.id, category: $0.category.rawValue, sizeBytes: $0.size, risk: $0.risk.title, reason: $0.reason)
        }
        return String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    static let instructions = """
    You are DiskSage's metadata-only cleanup advisor. Review only the supplied candidate metadata.
    Do not inspect the filesystem, run commands, or suggest paths. The host app controls deletion.
    Prefer regenerable caches and builds. Treat archives and simulator data as review-only.
    Recommend delete, keep, or review for every candidate exactly once. Keep each rationale short.
    """

    static func prompt(metadata: String, allowsCleanupRequests: Bool = false) -> String {
        """
        \(instructions)
        \(cleanupInstructions(allowed: allowsCleanupRequests))
        Return only JSON with this exact shape:
        {"summary":"short summary","cleanupRequested":false,"recommendations":[{"id":"UUID","decision":"delete|keep|review","rationale":"short reason"}]}
        Preserve every ID exactly. Candidate metadata:
        \(metadata)
        """
    }

    static func cleanupInstructions(allowed: Bool) -> String {
        allowed
            ? "Host tool clean_low_risk is available. Set cleanupRequested=true to request a fresh scan and cleanup of ALL scanner-classified low-risk generated files, when reclaiming space is useful and you recommend deleting at least one low-risk item. Otherwise return false. This field is the only tool request; the host enforces policy and logging."
            : "Host cleanup tools are disabled for this review. Return cleanupRequested=false."
    }

    static func validate(_ response: AgentResponse, expectedIDs: Set<UUID>) throws {
        let ids = response.recommendations.map(\.id)
        guard response.summary.utf8.count <= 1_000,
              ids.count == expectedIDs.count, Set(ids).count == ids.count, Set(ids) == expectedIDs,
              response.recommendations.allSatisfy({ $0.rationale.utf8.count <= 500 }) else {
            throw AdvisorError.invalidResponse
        }
    }

    static let responseSchema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["summary", "recommendations", "cleanupRequested"],
      "properties": {
        "summary": {"type": "string", "maxLength": 1000},
        "cleanupRequested": {"type": "boolean"},
        "recommendations": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "decision", "rationale"],
            "properties": {
              "id": {"type": "string", "format": "uuid"},
              "decision": {"type": "string", "enum": ["delete", "keep", "review"]},
              "rationale": {"type": "string", "maxLength": 500}
            }
          }
        }
      }
    }
    """

}
