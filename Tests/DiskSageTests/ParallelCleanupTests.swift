import Foundation
import Testing
@testable import DiskSage

struct ParallelCleanupTests {
    @Test func boundsWorkersLogsBeforeRemovalAndKeepsPartialResultsInInputOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = CleanupLogger(directory: root)
        let probe = WorkerProbe()
        let targets = (0..<10).map { candidate("item\($0)") }
        let service = CleanupService(logger: logger, maximumWorkers: 99, remove: { target, entry in
            try probe.remove(target, entry: entry)
        }, writeEvent: { event in
            try logger.append(event)
            if event.event == .itemStarted { probe.logged(event.name!) }
        })
        let task = Task { await service.delete(targets) }
        let reachedLimit = await waitUntil { probe.started.count == 4 }
        let initial = probe.started.count
        probe.release()
        let report = await task.value
        #expect(reachedLimit && initial == 4)
        #expect(probe.peak == 4)
        #expect(probe.allLoggedBeforeDelete)
        #expect(report.items.map(\.candidate.id) == targets.map(\.id))
        #expect(report.failures.map(\.candidate.name) == ["item1"])
        #expect(report.items.filter(\.succeeded).count == 9)
        #expect(report.removedEntryCount == 10)
        #expect(report.loggingError == nil)
    }

    @Test(arguments: ["runStart", "thirdItemStart", "firstItemFinish"])
    func loggingFailureStopsQueuedTargetsButDrainsAuthorizedWorkers(failurePoint: String) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = WorkerProbe()
        let targets = (0..<12).map { candidate("item\($0)") }
        let logger = CleanupLogger(directory: root)
        let service = CleanupService(logger: logger, maximumWorkers: 4, remove: { target, entry in
            try probe.remove(target, entry: entry)
        }, writeEvent: { event in
            if (failurePoint == "runStart" && event.event == .started) ||
                (failurePoint == "thirdItemStart" && event.event == .itemStarted && event.name == "item2") ||
                (failurePoint == "firstItemFinish" && event.event == .itemFinished) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try logger.append(event)
            if event.event == .itemStarted { probe.logged(event.name!) }
        })
        let task = Task { await service.delete(targets) }
        let expected = failurePoint == "runStart" ? 0 : (failurePoint == "thirdItemStart" ? 2 : 4)
        let ready = expected == 0 ? true : await waitUntil { probe.started.count == expected }
        probe.release()
        let report = await task.value
        #expect(ready)
        #expect(report.loggingError != nil)
        #expect(probe.started.count == expected)
        #expect(report.items.count == expected)
        #expect(probe.allLoggedBeforeDelete)
    }

    @Test func overlapsAndSimulatorOperationsAreSerializedWithoutBlockingIndependentTargets() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = WorkerProbe()
        let a = candidate("parent", path: "/fixture/project/.build")
        let nested = candidate("child", path: "/fixture/project/.build/subfolder")
        let independent = candidate("other")
        let simulator = candidate("simulator", mode: .simulatorDevices)
        let last = candidate("last")
        let targets = [a, nested, independent, simulator, last]
        let service = CleanupService(logger: CleanupLogger(directory: root), remove: { target, _ in
            try probe.remove(target, entry: {})
        })
        let task = Task { await service.delete(targets) }
        let twoReady = await waitUntil { probe.started.count == 2 }
        let first = Set(probe.started)
        probe.release()
        let report = await task.value
        #expect(twoReady && first == ["parent", "other"])
        #expect(report.failures.isEmpty)
        #expect(probe.overlapDetected == false)
        #expect(probe.started.firstIndex(of: "child")! > probe.started.firstIndex(of: "parent")!)
        #expect(probe.started.firstIndex(of: "last")! > probe.started.firstIndex(of: "simulator")!)
    }

    @Test func pathMatchingHandlesAliasesDuplicatesAndAdjacentNamesConservatively() {
        let a = candidate("a", path: "/fixture/Project/.build")
        #expect(CleanupScheduler.conflicts(a, candidate("nested", path: "/fixture/project/.build/sub")))
        #expect(CleanupScheduler.conflicts(a, candidate("same", path: "/fixture/Project/.build/")))
        #expect(!CleanupScheduler.conflicts(a, candidate("neighbor", path: "/fixture/Project/.build-other")))
        let sameInode = CleanupCandidate(url: URL(fileURLWithPath: "/different/alias"), name: "alias", category: .build,
            size: 0, risk: .low, reason: "Fixture", identity: a.identity)
        // Test nonzero identities rather than the unmeasured fixture's zero identity.
        let measured = CleanupCandidate(url: a.url, name: "measured", category: .build, size: 0, risk: .low,
            reason: "Fixture", identity: FileIdentity(device: 1, inode: 2))
        let alias = CleanupCandidate(url: sameInode.url, name: "alias", category: .build, size: 0, risk: .low,
            reason: "Fixture", identity: measured.identity)
        #expect(CleanupScheduler.conflicts(measured, alias))
    }

    private func candidate(_ name: String, path: String? = nil, mode: DeletionMode = .item) -> CleanupCandidate {
        CleanupCandidate(url: URL(fileURLWithPath: path ?? "/fixture/\(name)/.build"), name: name,
                         category: .build, size: 4096, risk: .low, reason: "Fixture", deletionMode: mode)
    }
    private func temporaryRoot() -> URL { URL(fileURLWithPath: "/private/tmp/disksage-parallel-\(UUID())") }
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
}

private final class WorkerProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var names: [String] = []
    private var loggedNames = Set<String>()
    private var active: [CleanupCandidate] = []
    private var maximum = 0
    private var overlap = false
    private var loggedFirst = true
    var started: [String] { condition.withLock { names } }
    var peak: Int { condition.withLock { maximum } }
    var overlapDetected: Bool { condition.withLock { overlap } }
    var allLoggedBeforeDelete: Bool { condition.withLock { loggedFirst } }

    func logged(_ name: String) { condition.withLock { _ = loggedNames.insert(name) } }
    func release() { condition.withLock { released = true; condition.broadcast() } }
    func remove(_ target: CleanupCandidate, entry: () -> Void) throws {
        condition.lock()
        loggedFirst = loggedFirst && loggedNames.contains(target.name)
        overlap = overlap || active.contains { CleanupScheduler.conflicts($0, target) }
        active.append(target)
        names.append(target.name)
        maximum = max(maximum, active.count)
        let deadline = Date().addingTimeInterval(10)
        while !released, condition.wait(until: deadline) { }
        condition.unlock()
        entry()
        condition.withLock { active.removeAll { $0.id == target.id } }
        if target.name == "item1" { throw CocoaError(.fileWriteNoPermission) }
    }
}
