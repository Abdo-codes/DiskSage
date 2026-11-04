import Foundation
import Testing
@testable import DiskSage

struct CodexAdvisorTests {
    @Test
    func acceptsExactlyOneRecommendationPerCandidate() throws {
        let ids = [UUID(), UUID()]
        let response = AgentResponse(
            summary: "Safe summary",
            recommendations: ids.map {
                AgentRecommendation(id: $0, decision: .keep, rationale: "Keep it")
            }
        )

        try CodexAdvisor().validate(response, expectedIDs: Set(ids))
    }

    @Test
    func rejectsDuplicateRecommendationIDs() {
        let id = UUID()
        let response = AgentResponse(
            summary: "Duplicate",
            recommendations: [
                AgentRecommendation(id: id, decision: .delete, rationale: "One"),
                AgentRecommendation(id: id, decision: .delete, rationale: "Two")
            ]
        )

        #expect(throws: CodexAdvisorError.self) {
            try CodexAdvisor().validate(response, expectedIDs: [id, UUID()])
        }
    }

    @Test
    func rejectsUnknownRecommendationID() {
        let expected = UUID()
        let response = AgentResponse(
            summary: "Unknown",
            recommendations: [
                AgentRecommendation(id: UUID(), decision: .delete, rationale: "Unknown item")
            ]
        )

        #expect(throws: CodexAdvisorError.self) {
            try CodexAdvisor().validate(response, expectedIDs: [expected])
        }
    }
}
