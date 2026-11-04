import Darwin
import Foundation
import Testing
@testable import DiskSage

struct CleanupLoggerTests {
    @Test
    func appendsTimestampedEventsAndRestrictsFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = CleanupLogger(directory: directory)
        let runID = UUID()
        try logger.append(CleanupLogEvent(runID: runID, trigger: .manual, event: .started))
        try logger.append(CleanupLogEvent(
            runID: runID, trigger: .manual, event: .itemFinished,
            path: "/example/cache\nwith-newline", succeeded: false, message: "Permission denied"
        ))

        let events = try readEvents(logger)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.runID == runID && $0.trigger == .manual })
        #expect(events[0].timestamp <= events[1].timestamp)
        #expect(events[1].path == "/example/cache\nwith-newline")
        #expect(events[1].message == "Permission denied")
        let attributes = try FileManager.default.attributesOfItem(atPath: logger.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func rotatesOldLogAndKeepsNewestEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = CleanupLogger(directory: directory, maximumBytes: 1)
        let firstID = UUID()
        let secondID = UUID()
        try logger.append(CleanupLogEvent(runID: firstID, trigger: .manual, event: .started))
        try logger.append(CleanupLogEvent(runID: secondID, trigger: .automatic, event: .started))
        #expect(try readEvents(logger).map(\.runID) == [secondID])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "cleanup.previous.jsonl").path))
    }

    @Test
    func refusesCleanupWhenLogCannotBeWritten() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Developer/.disksage-log-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: ".build")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: target.appending(path: "artifact"))
        let blocker = root.appending(path: "not-a-directory")
        try Data().write(to: blocker)
        var info = stat()
        try #require(lstat(target.path, &info) == 0)
        let candidate = CleanupCandidate(
            url: target, name: "Fixture", category: .build, size: 3, risk: .low, reason: "Fixture",
            identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        )
        let logger = CleanupLogger(directory: blocker.appending(path: "logs"))
        let report = await CleanupService(logger: logger).delete([candidate])
        #expect(report.loggingError != nil)
        #expect(report.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: target.appending(path: "artifact")) == Data([1, 2, 3]))
    }

    @Test
    func cleanupHistorySurvivesRotationAndIgnoresRoutineChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = CleanupLogger(directory: directory, maximumBytes: 1)
        let runID = UUID()
        try logger.append(CleanupLogEvent(runID: runID, trigger: .manual, event: .itemFinished,
                                         path: "/cache", name: "Package cache", succeeded: true))
        try logger.append(CleanupLogEvent(runID: runID, trigger: .manual, event: .finished,
                                         candidateCount: 1, failedCount: 0))
        #expect(try logger.recentCleanups().first?.itemNames == ["Package cache"])
        try logger.append(CleanupLogEvent(runID: UUID(), trigger: .automatic, event: .check))
        #expect(try logger.recentCleanups().map(\.id) == [runID])
    }

    private func readEvents(_ logger: CleanupLogger) throws -> [CleanupLogEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try Data(contentsOf: logger.fileURL).split(separator: 0x0A).map {
            try decoder.decode(CleanupLogEvent.self, from: Data($0))
        }
    }
}
