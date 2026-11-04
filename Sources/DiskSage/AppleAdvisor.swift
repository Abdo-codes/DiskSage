import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleAdvisor: Sendable {
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use the on-device model."
            case .unavailable(.modelNotReady): return "Apple’s model is still downloading or is not ready. Try again later."
            case .unavailable: return "Apple’s on-device model is currently unavailable."
            }
        }
        #endif
        return "Apple’s on-device model requires macOS 26 or later and a compatible build of DiskSage."
    }

    func recommend(candidates: [CleanupCandidate], allowsCleanupRequests: Bool = false) async throws -> AgentResponse {
        if let reason = Self.unavailableReason { throw AdvisorError.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return try await generate(candidates, allowsCleanupRequests: allowsCleanupRequests) }
        #endif
        throw AdvisorError.unavailable("Apple’s on-device model is unavailable.")
    }

    static func mapAdvice(_ advice: [(Int, AgentRecommendation.Decision, String)],
                          candidates: [CleanupCandidate]) throws -> [AgentRecommendation] {
        let indices = advice.map { $0.0 }
        guard indices.count == candidates.count, Set(indices) == Set(candidates.indices) else {
            throw AdvisorError.invalidResponse
        }
        return advice.map { AgentRecommendation(id: candidates[$0.0].id, decision: $0.1, rationale: $0.2) }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generate(_ candidates: [CleanupCandidate], allowsCleanupRequests: Bool) async throws -> AgentResponse {
        var recommendations: [AgentRecommendation] = []
        var cleanupRequested = false
        for batch in AdvisorContract.batches(candidates) {
            try Task.checkCancellation()
            let metadata = batch.enumerated().map { index, candidate in
                AppleCandidate(index: index, category: candidate.category.rawValue, sizeBytes: candidate.size,
                               risk: candidate.risk.title, reason: candidate.reason)
            }
            let prompt = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
            let session = LanguageModelSession(instructions: AdvisorContract.instructions + "\n" + AdvisorContract.cleanupInstructions(allowed: allowsCleanupRequests))
            let response = try await session.respond(to: "Review each candidate index exactly once:\n\(prompt)",
                generating: AppleBatch.self, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1_500))
            try Task.checkCancellation()
            let advice = response.content.recommendations.map {
                ($0.index, $0.decision.value, $0.rationale)
            }
            recommendations += try Self.mapAdvice(advice, candidates: batch)
            cleanupRequested = cleanupRequested || response.content.cleanupRequested
        }
        let response = AgentResponse(summary: "Reviewed \(candidates.count) items using Apple’s on-device model.",
                                     recommendations: recommendations, cleanupRequested: cleanupRequested)
        try AdvisorContract.validate(response, expectedIDs: Set(candidates.map(\.id)))
        return response
    }
    #endif
}

private struct AppleCandidate: Encodable {
    let index: Int
    let category: String
    let sizeBytes: Int64
    let risk: String
    let reason: String
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private enum AppleDecision {
    case delete, keep, review
    var value: AgentRecommendation.Decision {
        switch self {
        case .delete: .delete
        case .keep: .keep
        case .review: .review
        }
    }
}

@available(macOS 26.0, *)
@Generable
private struct AppleAdvice {
    @Guide(.range(0...7)) var index: Int
    var decision: AppleDecision
    @Guide(description: "One short sentence, under 100 characters.") var rationale: String
}

@available(macOS 26.0, *)
@Generable
private struct AppleBatch {
    @Guide(description: "Request the host clean_low_risk tool only when instructions allow it and cleanup is useful.")
    var cleanupRequested: Bool
    @Guide(.count(1...8)) var recommendations: [AppleAdvice]
}
#endif
