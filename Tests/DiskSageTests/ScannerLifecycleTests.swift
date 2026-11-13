import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

struct ScannerLifecycleTests {
    @Test func scannerOffersAllowedFixtureButRejectsSymlinkedAncestor() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer/.disksage-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "project/.build")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: target.appending(path: "artifact"))
        let good = try #require(DiskScanner.inspect(target, name: "Fixture", category: .build, risk: .low, reason: "Fixture"))
        try SafetyPolicy().validate(good)
        #expect(good.size >= 4096)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        #expect(DiskScanner.inspect(link.appending(path: ".build"), name: "Fixture", category: .build, risk: .low, reason: "Fixture") == nil)
    }

    @Test func changedTargetsAreDroppedBeforePublishingScanResults() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer/.disksage-stale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: ".build")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: target.appending(path: "artifact"))
        let original = try #require(DiskScanner.inspect(target, name: "Fixture", category: .build, risk: .low, reason: "Fixture"))
        #expect(DiskScanner.validated([original]).count == 1)
        try FileManager.default.moveItem(at: target, to: root.appending(path: "old-build"))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        #expect(DiskScanner.validated([original]).isEmpty)
    }

    @Test func alreadyCancelledScanReturnsNoCandidates() async throws {
        let gate = ScanGate()
        let task = Task {
            await gate.wait()
            return try await DiskScanner().scan()
        }
        task.cancel()
        await gate.open()
        #expect(try await task.value.isEmpty)
    }

    @MainActor @Test func cancelledScanCannotReplaceANewerOperation() async {
        let old = AsyncStream<[CleanupCandidate]>.makeStream()
        let current = AsyncStream<[CleanupCandidate]>.makeStream()
        let cancelled = LockIsolated(false)
        let calls = LockIsolated(0)
        old.continuation.onTermination = { if case .cancelled = $0 { cancelled.setValue(true) } }
        let fresh = FeatureTestSupport.candidate("Fresh")
        let store = FeatureTestSupport.store {
            $0.diskSage.scan = {
                let number = calls.withValue { count in count += 1; return count }
                for await values in number == 1 ? old.stream : current.stream { return values }
                return []
            }
        }
        let firstTask = await store.send(.scanRequested(.review)) {
            $0.activityRevision = 1; $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Scanning generated files…"
        }
        await store.send(.cancelOperation) {
            $0.activityRevision = 2; $0.operation = .idle; $0.operationID = nil; $0.statusMessage = "Operation cancelled"
        }
        await firstTask.finish()
        #expect(cancelled.value)
        await store.send(.scanRequested(.review)) {
            $0.activityRevision = 3; $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(1)
            $0.statusMessage = "Scanning generated files…"
        }
        await store.send(.scanFinished(FeatureTestSupport.id(0), .review, [], 9999, DashboardSnapshot()))
        current.continuation.yield([fresh])
        await store.receive(.scanFinished(FeatureTestSupport.id(1), .review, [fresh], 100, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = [fresh]; $0.selection = [fresh.id]
            $0.freeSpaceBytes = 100; $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.statusMessage = "Found 1 candidates"
        }
        await store.finish()
    }
}

private actor ScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
