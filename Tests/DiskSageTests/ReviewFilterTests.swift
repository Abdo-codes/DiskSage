import Foundation
import Testing
@testable import DiskSage

struct ReviewFilterTests {
    @Test func searchMatchesNamesAndPathsAndCombinesWithRisk() {
        let low = candidate("Swift Output", path: "/project/alpha/.build", risk: .low)
        let medium = candidate("Build", path: "/project/alpha/build", risk: .medium)
        let high = candidate("Archives", path: "/project/beta/archives", risk: .high)
        let items = [low, medium, high]
        #expect(ReviewFilter.candidates(items, query: " ALPHA ", risk: .all).map(\.id) == [low.id, medium.id])
        #expect(ReviewFilter.candidates(items, query: "swift", risk: .lowRisk).map(\.id) == [low.id])
        #expect(ReviewFilter.candidates(items, query: "", risk: .needsReview).map(\.id) == [medium.id, high.id])
        #expect(ReviewFilter.candidates(items, query: "beta", risk: .lowRisk).isEmpty)
    }

    @Test func changingVisibleSelectionPreservesHiddenSelectionsButRejectsUnknownIDs() {
        let hidden = UUID(), visible = UUID(), another = UUID(), unknown = UUID()
        let selected = ReviewFilter.mergeSelection([hidden, visible], visibleSelection: [another, unknown], visibleIDs: [visible, another])
        #expect(selected == [hidden, another])
        #expect(ReviewFilter.mergeSelection(selected, visibleSelection: [], visibleIDs: [visible, another]) == [hidden])
    }

    private func candidate(_ name: String, path: String, risk: RiskLevel) -> CleanupCandidate {
        CleanupCandidate(url: URL(fileURLWithPath: path), name: name, category: .build, size: 1, risk: risk, reason: "Fixture")
    }
}
