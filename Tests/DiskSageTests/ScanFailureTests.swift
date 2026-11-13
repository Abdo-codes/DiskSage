import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct ScanFailureTests {
    @Test func failedScanShowsAnErrorAndKeepsTheLastList() async {
        let old = FeatureTestSupport.candidate("old")
        var state = AppFeature.State()
        state.candidates = [old]
        let failure = FeatureFailure(message: "lsof exceeded its output limit.")
        let store = FeatureTestSupport.store(state) { $0.diskSage.scan = { throw failure } }
        await store.send(.scanRequested(.review)) {
            $0.activityRevision = 1; $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Scanning generated files…"
        }
        await store.receive(.scanFailed(FeatureTestSupport.id(0), .review, failure)) {
            $0.operation = .idle; $0.operationID = nil
            $0.errorMessage = failure.message; $0.statusMessage = "Scan failed"
        }
        #expect(store.state.candidates == [old])
        await store.finish()
    }

    @Test func scanWarningIsShownWithTheResults() async {
        let found = FeatureTestSupport.candidate("found")
        let warning = "Xcode generated files was skipped. It has more than 1,000,000 files and folders, so DiskSage did not check it."
        let store = FeatureTestSupport.store {
            $0.diskSage.scan = { ScanReport(candidates: [found], warnings: [warning]) }
        }
        await store.send(.scanRequested(.review)) {
            $0.activityRevision = 1; $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Scanning generated files…"
        }
        await store.receive(.scanWarned(FeatureTestSupport.id(0), [warning])) { $0.scanWarnings = [warning] }
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .review, [found], 100, DashboardSnapshot())) {
            $0.candidates = [found]; $0.selection = [found.id]; $0.freeSpaceBytes = 100
            $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.operation = .idle; $0.operationID = nil; $0.statusMessage = "Found 1 candidates"
        }
        await store.finish()
    }

    @Test func scanWarningStaysAfterAutomaticCleanup() async {
        let low = FeatureTestSupport.candidate("low")
        let report = CleanupReport(items: [CleanupItemResult(candidate: low, removedBytes: 4096, errorDescription: nil)],
                                   freeSpaceBefore: 100, freeSpaceAfter: 200)
        let store = FeatureTestSupport.store {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.scan = { ScanReport(candidates: [low], warnings: ["A folder was skipped."]) }
            $0.diskSage.cleanup = { _, _, _ in report }
        }
        store.exhaustivity = .off
        await store.send(.monitorTick)
        await store.receive(\.scanWarned) { $0.scanWarnings = ["A folder was skipped."] }
        await store.receive(\.cleanupFinished) { $0.candidates = []; $0.cleanupReport = report }
        #expect(store.state.scanWarnings == ["A folder was skipped."])
        #expect(store.state.errorMessage == nil)
    }

    @Test func processOutputAboveTheOldEightMegabyteCapIsRead() throws {
        // 12 MB of output: the default limit refuses it, a larger limit reads all of it.
        let arguments = ["if=/dev/zero", "bs=1048576", "count=12"]
        #expect(throws: FeatureFailure.self) { try WorktreeGitProcess().execute("/bin/dd", arguments) }
        let output = try WorktreeGitProcess().execute("/bin/dd", arguments, outputLimit: 64_000_000)
        #expect(output.code == 0)
        #expect(output.data.count >= 12 * 1_048_576)
    }

    @Test func liveActivityCaptureWorksOnThisMac() throws {
        // This runs the real lsof. It failed on a Mac with more than 8 MB of open-file output.
        let activity = try CleanupActivity.capture()
        #expect(!activity.paths.isEmpty)
    }

    @Test func liveWorktreeActivityCaptureWorksOnThisMac() throws {
        // The worktree check uses its own lsof call. It had the same 8 MB limit.
        #expect(try !WorktreeActivity.capture(WorktreeGitProcess()).isEmpty)
    }
}
