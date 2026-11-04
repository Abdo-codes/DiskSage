import Foundation
import Testing
@testable import DiskSage

struct CleanupHistoryTests {
    @Test
    func completedCleanupKeepsNamesAndRiskIndependentOfRoutineChecks() {
        let run = UUID()
        let events = [
            CleanupLogEvent(runID: run, trigger: .manual, event: .itemFinished,
                            path: "/Users/example/Library/Developer/CoreSimulator/Devices", succeeded: true),
            CleanupLogEvent(runID: run, trigger: .manual, event: .itemFinished,
                            path: "/example/.build", succeeded: false, message: "Permission denied"),
            CleanupLogEvent(runID: run, trigger: .manual, event: .finished,
                            estimatedRemovedBytes: 38_000_000_000, actualRecoveredBytes: 174_000_000,
                            candidateCount: 2, failedCount: 1),
            CleanupLogEvent(runID: UUID(), trigger: .automatic, event: .check)
        ]
        let history = CleanupHistory.summaries(from: events)
        #expect(history.count == 1)
        #expect(history[0].itemNames == ["Simulator devices"])
        #expect(history[0].succeededCount == 1)
        #expect(history[0].failedCount == 1)
        #expect(history[0].items.count == 2)
        #expect(history[0].estimatedRemovedBytes == 38_000_000_000)
        #expect(history[0].availableSpaceChange == 174_000_000)
    }

    @Test
    func newRecordsUseTheirDisplayNameAndUnfinishedRunsStayOutOfHistory() {
        let run = UUID()
        let events = [
            CleanupLogEvent(runID: run, trigger: .automatic, event: .itemFinished,
                            path: "/cache/custom", name: "Package cache", succeeded: true),
            CleanupLogEvent(runID: run, trigger: .automatic, event: .finished, candidateCount: 1, failedCount: 0),
            CleanupLogEvent(runID: UUID(), trigger: .manual, event: .itemStarted, path: "/pending")
        ]
        #expect(CleanupHistory.summaries(from: events).first?.itemNames == ["Package cache"])
    }

    @Test
    func rotatedItemDetailsAreReportedAsUnavailable() {
        let event = CleanupLogEvent(runID: UUID(), trigger: .manual, event: .finished, candidateCount: 3, failedCount: 0)
        let summary = CleanupHistory.summaries(from: [event])[0]
        #expect(summary.succeededCount == 3)
        #expect(summary.items.isEmpty)
        #expect(summary.itemNames.isEmpty)
    }

    @Test
    func loggingFailureIsAWarningEvenBeforeAnyItemWasAttempted() {
        let event = CleanupLogEvent(runID: UUID(), trigger: .automatic, event: .finished,
                                   message: "Log could not be written", candidateCount: 0, failedCount: 0)
        let run = CleanupHistory.summaries(from: [event])[0]
        #expect(run.hasWarnings)
        #expect(run.error == "Log could not be written")
        #expect(run.itemDescription == "No items confirmed fully removed.")
    }
}
