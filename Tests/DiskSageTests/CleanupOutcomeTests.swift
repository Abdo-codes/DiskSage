import Foundation
import Testing
@testable import DiskSage

struct CleanupOutcomeTests {
    @Test func completionPresentationUsesConfirmedResultsInsteadOfMutableOperationStatus() {
        let candidate = CleanupCandidate(url: URL(fileURLWithPath: "/fixture/build"), name: "Fixture",
            category: .build, size: 4096, risk: .low, reason: "Fixture")
        let success = CleanupItemResult(candidate: candidate, removedBytes: 4096, errorDescription: nil)
        let failure = CleanupItemResult(candidate: candidate, removedBytes: 0, errorDescription: "Permission denied")
        let completed = CleanupOutcome(report: CleanupReport(items: [success], freeSpaceBefore: 100, freeSpaceAfter: 100))
        #expect(completed.title.contains(Int64(4096).diskSize))
        #expect(!completed.hasWarnings)
        let partial = CleanupOutcome(report: CleanupReport(items: [success, failure], freeSpaceBefore: 100, freeSpaceAfter: 200))
        #expect(partial.title.contains("1 deleted, 1 failed"))
        #expect(partial.hasWarnings)
        let unlogged = CleanupOutcome(report: CleanupReport(items: [], freeSpaceBefore: 100, freeSpaceAfter: 100, loggingError: "Unavailable"))
        #expect(unlogged.title.hasPrefix("Cleanup stopped"))
        #expect(unlogged.hasWarnings)
    }
}
