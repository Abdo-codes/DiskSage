import Foundation
import Testing
@testable import DiskSage

struct DashboardDataTests {
    @Test(arguments: [(Int64(100), Int64(25), Int64(75)), (100, 200, 0), (100, -10, 100), (0, 25, 0)])
    func diskUsageStaysWithinCapacity(values: (Int64, Int64, Int64)) {
        let usage = DiskUsageSnapshot(name: "Disk", totalBytes: values.0, availableBytes: values.1)
        #expect(usage.usedBytes == values.2)
        #expect((0...1).contains(usage.usedFraction))
        #expect(usage.usedBytes + usage.availableBytes == usage.totalBytes)
    }

    @Test
    func cleanupBreakdownKeepsSensitiveItemsSeparate() {
        let candidates = [candidate(.cache, .low, 10), candidate(.build, .low, 20),
                          candidate(.build, .medium, 30), candidate(.archive, .high, 40)]
        let breakdown = CleanupBreakdown(candidates: candidates)
        #expect(breakdown.totalBytes == 100)
        #expect(breakdown.lowRiskBytes == 30)
        #expect(breakdown.reviewBytes == 70)
        #expect(breakdown.categories.map(\.category) == [.cache, .build, .archive])
        #expect(breakdown.categories.map(\.bytes) == [10, 50, 40])
    }

    private func candidate(_ category: CandidateCategory, _ risk: RiskLevel, _ size: Int64) -> CleanupCandidate {
        CleanupCandidate(url: URL(fileURLWithPath: "/fixture/\(UUID())"), name: "Fixture",
                         category: category, size: size, risk: risk, reason: "Fixture")
    }
}
