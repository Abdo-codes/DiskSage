import Darwin
import Foundation
import Testing
@testable import DiskSage

struct CleanupServiceTests {
    @Test
    func reportsPartialSuccessAndContinuesAfterFailure() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Developer/.disksage-cleanup-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let removable = root.appending(path: ".build", directoryHint: .isDirectory)
        let changed = root.appending(path: "build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: removable, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: removable.appending(path: "artifact"))

        let good = CleanupCandidate(
            url: removable,
            name: ".build",
            category: .build,
            size: 4096,
            risk: .low,
            reason: "Fixture",
            identity: try identity(of: removable)
        )
        let bad = CleanupCandidate(
            url: changed,
            name: "build",
            category: .build,
            size: 4096,
            risk: .medium,
            reason: "Fixture",
            identity: FileIdentity(device: UInt64.max, inode: UInt64.max)
        )

        let logger = CleanupLogger(directory: root.appending(path: "logs"))
        let progress = ProgressRecorder()
        let report = await CleanupService(logger: logger, maximumWorkers: 1).delete([bad, good], trigger: .automatic) { event in
            await progress.record(event)
        }
        let updates = await progress.updates
        #expect(updates == ["start:build:0/2", "finish:build:false:1/2", "start:.build:1/2", "finish:.build:true:2/2"])

        #expect(report.items.count == 2)
        #expect(report.items.filter(\.succeeded).count == 1)
        #expect(report.items.filter { !$0.succeeded }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: removable.path))
        #expect(FileManager.default.fileExists(atPath: changed.path))
        #expect(report.loggingError == nil)
        #expect(report.removedEntryCount == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try Data(contentsOf: logger.fileURL).split(separator: 0x0A).map {
            try decoder.decode(CleanupLogEvent.self, from: Data($0))
        }
        #expect(events.map(\.event) == [.started, .itemStarted, .itemFinished, .itemStarted, .itemFinished, .finished])
        #expect(events.allSatisfy { $0.trigger == .automatic && $0.runID == events[0].runID })
        #expect(events[2].path == changed.path)
        #expect(events[2].succeeded == false)
        #expect(events[2].message != nil)
        #expect(events[4].path == removable.path)
        #expect(events[4].succeeded == true)
        #expect(events[4].estimatedRemovedBytes == 4096)
        #expect(events.last?.actualRecoveredBytes == report.actualRecoveredBytes)
        #expect(events.last?.removedEntryCount == 2)
    }

    private func identity(of url: URL) throws -> FileIdentity {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

private actor ProgressRecorder {
    var updates: [String] = []
    func record(_ event: CleanupProgress) {
        switch event {
        case .entriesRemoved: break
        case let .started(candidate, completed, total):
            updates.append("start:\(candidate.name):\(completed)/\(total)")
        case let .finished(result, completed, total):
            updates.append("finish:\(result.candidate.name):\(result.succeeded):\(completed)/\(total)")
        }
    }
}
