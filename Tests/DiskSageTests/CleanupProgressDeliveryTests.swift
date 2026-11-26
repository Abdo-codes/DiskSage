import Foundation
import Testing
@testable import DiskSage

struct CleanupProgressDeliveryTests {
    @Test func slowProgressConsumerCannotBlockFileRemovalAndAllUpdatesDrainBeforeReturn() async throws {
        let fakeHome = URL(fileURLWithPath: "/private/tmp/DS-test-home-\(UUID().uuidString)", isDirectory: true)
        let root = fakeHome.appending(path: "Developer/progress-test")
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let target = root.appending(path: ".build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: target.appending(path: "artifact"))
        let candidate = try #require(DiskScanner.inspect(target, name: "Fixture", category: .build, risk: .low, reason: "Fixture", home: fakeHome))
        let gate = DeliveryGate()
        let logger = CleanupLogger(directory: root.appending(path: "logs"))
        let task = Task {
            await CleanupService(logger: logger, home: fakeHome).delete([candidate]) { update in await gate.consume(update) }
        }
        await gate.waitUntilStarted()
        // The UI consumer is suspended, but the filesystem worker must be able to finish.
        let deadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: target.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let removedWhileBlocked = !FileManager.default.fileExists(atPath: target.path)
        await gate.open()
        let report = await task.value
        #expect(removedWhileBlocked)
        #expect(report.items.first?.succeeded == true)
        #expect(report.removedEntryCount == 2)
        #expect(await gate.lastEntryCount == 2)
        #expect(await gate.didFinish)
    }
}

private actor DeliveryGate {
    var lastEntryCount = 0
    var didFinish = false
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func consume(_ update: CleanupProgress) async {
        switch update {
        case .started:
            started = true
            startWaiter?.resume()
            startWaiter = nil
            if !isOpen { await withCheckedContinuation { releaseWaiter = $0 } }
        case let .entriesRemoved(count): lastEntryCount = count
        case .finished: didFinish = true
        }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func open() {
        isOpen = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
