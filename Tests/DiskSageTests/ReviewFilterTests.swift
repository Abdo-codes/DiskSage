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

    @Test func filtersByCategorySearchesCategoryTitleAndSortsDeterministically() {
        let bigCache = candidate("Cargo registry", path: "/home/.cargo/registry", category: .cache, size: 500, risk: .low)
        let smallBuild = candidate("Alpha build", path: "/home/dev/alpha/.build", category: .build, size: 100, risk: .low)
        let sim = candidate("iPhone 16", path: "/home/sim/1", category: .simulator, size: 900, risk: .medium)
        let items = [smallBuild, bigCache, sim]

        #expect(ReviewFilter.candidates(items, query: "", risk: .all, category: .cache).map(\.id) == [bigCache.id])
        #expect(ReviewFilter.candidates(items, query: "", risk: .all, category: .simulator).map(\.id) == [sim.id])
        #expect(ReviewFilter.candidates(items, query: "simulator", risk: .all).map(\.id) == [sim.id])
        #expect(ReviewFilter.candidates(items, query: "", risk: .all, sort: .largest).map(\.id) == [sim.id, bigCache.id, smallBuild.id])
        #expect(ReviewFilter.candidates(items, query: "", risk: .all, sort: .name).map(\.id) == [smallBuild.id, bigCache.id, sim.id])
        #expect(ReviewFilter.candidates(items, query: "", risk: .all, sort: .risk).map(\.id) == [bigCache.id, smallBuild.id, sim.id])
    }

    private func candidate(_ name: String, path: String, category: CandidateCategory = .build,
                           size: Int64 = 1, risk: RiskLevel) -> CleanupCandidate {
        CleanupCandidate(url: URL(fileURLWithPath: path), name: name, category: category, size: size, risk: risk, reason: "Fixture")
    }
}
