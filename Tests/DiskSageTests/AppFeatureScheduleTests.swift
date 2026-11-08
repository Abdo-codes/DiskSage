import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureScheduleTests {
    private func schedule(_ number: Int = 9, frequency: CleanupSchedule.Frequency = .daily) -> CleanupSchedule {
        CleanupSchedule(id: FeatureTestSupport.id(number), folder: URL(fileURLWithPath: "/fixture/cache"),
            folderIdentity: FileIdentity(device: 1, inode: 2), frequency: frequency,
            oneTimeDate: FeatureTestSupport.epoch.addingTimeInterval(-10),
            nextRun: FeatureTestSupport.epoch.addingTimeInterval(-10))
    }
    private func initial(_ value: CleanupSchedule) -> AppFeature.State {
        var state = AppFeature.State(); state.schedules = [value]
        state.schedulesLoaded = true; state.isScheduling = true
        return state
    }
    private func target(_ value: CleanupSchedule) -> CleanupCandidate {
        CleanupCandidate(url: value.folder, name: "cache", category: .cache, size: 4096,
            risk: .low, reason: "Fixture", identity: value.folderIdentity, deletionMode: value.scope == .lowRisk ? .generatedFiles : .contents)
    }
    private func claim(_ state: inout AppFeature.State, _ value: CleanupSchedule) {
        var claimed = value
        claimed.lastRun = FeatureTestSupport.epoch
        claimed.nextRun = claimed.nextOccurrence(after: FeatureTestSupport.epoch)
        claimed.lastResult = "Cleanup started. If DiskSage quits, check History before running again."
        state.schedules = [claimed]; state.activityRevision = 1
        state.operation = .scanning; state.operationID = FeatureTestSupport.id(0)
        state.activeSchedule = ScheduledCleanupRun(schedule: claimed, operationID: FeatureTestSupport.id(0))
        state.statusMessage = "Checking scheduled folder cache…"
    }

    @Test(arguments: [CleanupSchedule.Frequency.daily, .once])
    func dueRunsPersistBeforeScanningUseSharedCleanupAndCannotRepeat(frequency: CleanupSchedule.Frequency) async {
        let value = schedule(frequency: frequency), candidate = target(value)
        let writes = LockIsolated<[[CleanupSchedule]]>([])
        let expectedDate = FeatureTestSupport.epoch
        let report = CleanupReport(items: [CleanupItemResult(candidate: candidate, removedBytes: 4096, errorDescription: nil)],
            freeSpaceBefore: 100, freeSpaceAfter: 200)
        let store = FeatureTestSupport.store(initial(value)) {
            $0.schedules.save = { values in writes.withValue { $0.append(values) } }
            $0.schedules.scan = { _ in
                #expect(writes.value.count == 1)
                #expect(writes.value[0][0].lastRun == expectedDate)
                return [candidate]
            }
            $0.schedules.cleanup = { authorization, targets, _ in
                #expect(authorization.hasSameAuthorization(as: value) && targets == [candidate])
                return report
            }
        }
        await store.send(.scheduleTick) { claim(&$0, value) }
        await store.receive(.scheduledScanFinished(FeatureTestSupport.id(0), .success([candidate]))) {
            $0.activityRevision = 2; $0.operationID = FeatureTestSupport.id(1); $0.operation = .cleaning
            $0.cleanupTotalCount = 1; $0.cleanupCurrentItem = "Preparing cleanup…"
            $0.statusMessage = "Deleting approved candidates…"
        }
        await store.receive(.cleanupFinished(FeatureTestSupport.id(1), report, DashboardSnapshot())) {
            $0.cleanupReport = report; $0.lastRecoveredBytes = 100; $0.freeSpaceBytes = 200
            $0.dashboardRevision = 1; $0.operation = .idle; $0.operationID = nil; $0.activeSchedule = nil
            $0.statusMessage = "Deleted 1 item(s) · \(Int64(4096).diskSize) estimated"
            $0.schedules[0].lastResult = $0.statusMessage
            if frequency == .once { $0.schedules[0].isEnabled = false }
        }
        await store.send(.scheduleTick)
        #expect(writes.value.count == 2)
        await store.finish()
    }

    @Test(arguments: [AppOperation.scanning, .automaticScan, .advising, .cleaning, .automaticCleanup])
    func busyOperationsDeferDueRunsWithoutConsumingThem(operation: AppOperation) async {
        var state = initial(schedule()); state.operation = operation
        let writes = LockIsolated(0)
        let store = FeatureTestSupport.store(state) { $0.schedules.save = { _ in writes.withValue { $0 += 1 } } }
        await store.send(.scheduleTick)
        #expect(writes.value == 0)
        await store.finish()
    }

    @Test func aManualConfirmationAlsoDefersDueSchedules() async {
        var state = initial(schedule())
        state.pendingDeletionRequest = DeletionRequest(id: FeatureTestSupport.id(50), candidates: [target(schedule())])
        let store = FeatureTestSupport.store(state)
        await store.send(.scheduleTick)
        await store.finish()
    }

    @Test func persistenceFailurePreventsScanningAndLeavesOccurrenceUnconsumed() async {
        let error = CocoaError(.fileWriteNoPermission)
        let store = FeatureTestSupport.store(initial(schedule())) { $0.schedules.save = { _ in throw error } }
        await store.send(.scheduleTick) { $0.scheduleError = error.localizedDescription; $0.schedulingBlocked = true }
        await store.finish()
    }

    @Test func mandatoryCheckLoggingFailureNeverReachesScanningOrDeletion() async {
        let value = schedule(), error = FeatureFailure(message: "Log is unavailable")
        let store = FeatureTestSupport.store(initial(value)) { $0.diskSage.logCheck = { _ in throw error } }
        await store.send(.scheduleTick) { claim(&$0, value) }
        await store.receive(.scheduledScanFinished(FeatureTestSupport.id(0), .failure(error))) {
            $0.operation = .idle; $0.operationID = nil; $0.activeSchedule = nil
            $0.statusMessage = "Cleanup failed: Log is unavailable"; $0.schedules[0].lastResult = $0.statusMessage
            $0.errorMessage = error.message
        }
        await store.finish()
    }

    @Test(arguments: [false, true])
    func changingEnablementWhileScanningRevokesThePendingDeletion(reenable: Bool) async {
        let value = schedule(), candidate = target(value)
        let scan = AsyncStream<[CleanupCandidate]>.makeStream()
        let store = FeatureTestSupport.store(initial(value)) {
            $0.schedules.scan = { _ in for await values in scan.stream { return values }; return [] }
        }
        await store.send(.scheduleTick) { claim(&$0, value) }
        await store.send(.setScheduleEnabled(value.id, false)) { $0.schedules[0].isEnabled = false; $0.schedules[0].revision = 1 }
        if reenable {
            await store.send(.setScheduleEnabled(value.id, true)) { $0.schedules[0].isEnabled = true; $0.schedules[0].revision = 2 }
        }
        scan.continuation.yield([candidate]); scan.continuation.finish()
        await store.receive(.scheduledScanFinished(FeatureTestSupport.id(0), .success([candidate]))) {
            $0.operation = .idle; $0.operationID = nil; $0.activeSchedule = nil
            $0.statusMessage = "Skipped: schedule changed or was paused."
            $0.schedules[0].lastResult = $0.statusMessage
        }
        await store.finish()
    }

    @Test func scanCannotExpandFolderScopeOrReturnSensitiveTargets() async {
        let value = schedule(), unsafe = FeatureTestSupport.candidate("outside", risk: .high)
        let store = FeatureTestSupport.store(initial(value)) { $0.schedules.scan = { _ in [unsafe] } }
        await store.send(.scheduleTick) { claim(&$0, value) }
        await store.receive(.scheduledScanFinished(FeatureTestSupport.id(0), .success([unsafe]))) {
            $0.operation = .idle; $0.operationID = nil; $0.activeSchedule = nil
            $0.statusMessage = "Cleanup refused: scan returned an unauthorized target."
            $0.schedules[0].lastResult = $0.statusMessage
        }
        await store.finish()
    }

    @Test func timerLoadsPersistedRulesAndStopsWithoutLeakingEffects() async {
        let clock = TestClock()
        var value = schedule(); value.nextRun = FeatureTestSupport.epoch.addingTimeInterval(600)
        let loaded = value
        let store = FeatureTestSupport.store {
            $0.continuousClock = clock; $0.schedules.load = { [loaded] }
        }
        let timer = await store.send(.startScheduling) {
            $0.schedules = [loaded]; $0.schedulesLoaded = true; $0.isScheduling = true
        }
        await store.receive(.scheduleTick)
        await clock.advance(by: .seconds(30))
        await store.receive(.scheduleTick)
        await store.send(.stopScheduling) { $0.isScheduling = false }
        await timer.finish()
        await store.finish()
    }

    @Test func editsAndEnablementPersistAndPastOneTimeRulesCannotBeEnabled() async {
        var state = AppFeature.State(); state.schedulesLoaded = true
        let value = schedule(), writes = LockIsolated<[[CleanupSchedule]]>([])
        let store = FeatureTestSupport.store(state) {
            $0.schedules.save = { values in writes.withValue { $0.append(values) } }
        }
        var saved = value; saved.nextRun = saved.nextOccurrence(after: FeatureTestSupport.epoch)
        saved.revision = 1
        await store.send(.saveSchedule(value)) { $0.schedules = [saved] }
        await store.send(.setScheduleEnabled(value.id, false)) { $0.schedules[0].isEnabled = false; $0.schedules[0].revision = 2 }
        await store.send(.removeSchedule(value.id)) { $0.schedules = [] }
        let past = schedule(frequency: .once)
        await store.send(.saveSchedule(past)) { $0.scheduleError = "Choose a future cleanup time." }
        #expect(writes.value.count == 3)
        await store.finish()
    }

    @Test func stoppingSchedulingCancelsPreflightWithoutStartingDeletion() async {
        let value = schedule(), clock = TestClock()
        let stream = AsyncStream<[CleanupCandidate]>.makeStream()
        let cancelled = LockIsolated(false)
        stream.continuation.onTermination = { if case .cancelled = $0 { cancelled.setValue(true) } }
        let store = FeatureTestSupport.store(initial(value)) {
            $0.continuousClock = clock
            $0.schedules.scan = { _ in for await result in stream.stream { return result }; return [] }
        }
        await store.send(.scheduleTick) { claim(&$0, value) }
        await store.send(.stopScheduling) {
            $0.isScheduling = false; $0.operation = .idle; $0.operationID = nil; $0.activeSchedule = nil
            $0.statusMessage = "Scheduled cleanup cancelled."; $0.schedules[0].lastResult = $0.statusMessage
        }
        await store.finish()
        #expect(cancelled.value)
    }

    @Test func recurringRulesFollowTimeZoneChangesWithoutFiringAtTheOldLocalTime() async {
        var value = schedule(); value.timeZoneIdentifier = "Europe/Amsterdam"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let changedCalendar = calendar
        let store = FeatureTestSupport.store(initial(value)) { $0.calendar = changedCalendar }
        await store.send(.scheduleTick) {
            $0.schedules[0].timeZoneIdentifier = "America/Los_Angeles"
            $0.schedules[0].nextRun = value.nextOccurrence(after: FeatureTestSupport.epoch, calendar: changedCalendar)
        }
        await store.finish()
    }

    @Test func invalidDraftDoesNotBlockAnExistingRuleAndEmptyRunsAreConsumedOnce() async {
        let value = schedule()
        let store = FeatureTestSupport.store(initial(value)) { $0.schedules.scan = { _ in [] } }
        await store.send(.saveSchedule(schedule(frequency: .once))) { $0.scheduleError = "Choose a future cleanup time." }
        await store.send(.scheduleTick) { claim(&$0, value); $0.scheduleError = nil }
        await store.receive(.scheduledScanFinished(FeatureTestSupport.id(0), .success([]))) {
            $0.operation = .idle; $0.operationID = nil; $0.activeSchedule = nil
            $0.statusMessage = "No eligible inactive files to clean."
            $0.schedules[0].lastResult = $0.statusMessage
        }
        await store.send(.scheduleTick)
        await store.finish()
    }

    @Test func unreadableScheduleStorageBlocksChangesUntilReloaded() async {
        let error = FeatureFailure(message: "Invalid schedule file")
        let store = FeatureTestSupport.store { $0.schedules.load = { throw error } }
        await store.send(.startScheduling) {
            $0.schedulingBlocked = true
            $0.scheduleError = "Schedules could not be loaded: Invalid schedule file"
        }
        await store.send(.saveSchedule(schedule()))
        await store.send(.scheduleTick)
        await store.finish()
    }
}
