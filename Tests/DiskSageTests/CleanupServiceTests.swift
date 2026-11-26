import Darwin
import Foundation
import Testing
@testable import DiskSage

struct CleanupServiceTests {
    @Test
    func reportsPartialSuccessAndContinuesAfterFailure() async throws {
        let fakeHome = URL(fileURLWithPath: "/private/tmp/DS-test-home-\(UUID().uuidString)", isDirectory: true)
        let root = fakeHome.appending(path: "Developer/cleanup-test", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
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
        let report = await CleanupService(logger: logger, maximumWorkers: 1, home: fakeHome).delete([bad, good], trigger: .automatic) { event in
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

    @Test
    func deletesContentsOfOwnedReadOnlyDirectoriesAndRestoresRootMode() throws {
        let fakeHome = URL(fileURLWithPath: "/private/tmp/DS-test-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let cache = fakeHome.appending(path: "Library/Caches/ro-eco-cache", directoryHint: .isDirectory)
        let nested = cache.appending(path: "nested/sub", directoryHint: .isDirectory)
        let emptySub = cache.appending(path: "empty-ro", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptySub, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 1024).write(to: nested.appending(path: "file.bin"))
        try FileManager.default.createSymbolicLink(at: nested.appending(path: "alias"), withDestinationURL: fakeHome)
        let lockedDirs = [nested, cache.appending(path: "nested", directoryHint: .isDirectory), emptySub, cache]
        for dir in lockedDirs { #expect(chmod(dir.path, 0o555) == 0) }
        defer { for dir in lockedDirs.reversed() { chmod(dir.path, 0o755) } }

        let candidate = CleanupCandidate(
            url: cache,
            name: "Read-only cache",
            category: .cache,
            size: 1024,
            risk: .low,
            reason: "Fixture",
            identity: try identity(of: cache),
            deletionMode: .contents
        )
        var removedCount = 0
        try SecureFileDeleter.delete(candidate, entryRemoved: { removedCount += 1 })
        #expect(removedCount == 5)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        var rootInfo = stat()
        #expect(lstat(cache.path, &rootInfo) == 0)
        #expect(rootInfo.st_mode & 0o777 == 0o555)
    }

    @Test(arguments: [DeletionMode.item, DeletionMode.projectCache])
    func deletesReadOnlyTargetInsideReadOnlyParentAndRestoresParentMode(mode: DeletionMode) throws {
        let fakeHome = URL(fileURLWithPath: "/private/tmp/DS-test-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let parent = fakeHome.appending(path: "Developer/locked-parent", directoryHint: .isDirectory)
        let target = parent.appending(path: "node_modules", directoryHint: .isDirectory)
        let nested = target.appending(path: "pkg", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 512).write(to: nested.appending(path: "artifact.bin"))
        for dir in [nested, target, parent] { #expect(chmod(dir.path, 0o555) == 0) }
        defer { for dir in [parent, target, nested] { chmod(dir.path, 0o755) } }

        let candidate = CleanupCandidate(
            url: target,
            name: "node_modules",
            category: .cache,
            size: 512,
            risk: .low,
            reason: "Fixture",
            identity: try identity(of: target),
            deletionMode: mode
        )
        var removedCount = 0
        try SecureFileDeleter.delete(candidate, entryRemoved: { removedCount += 1 })
        #expect(removedCount == 3)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        var parentInfo = stat()
        #expect(lstat(parent.path, &parentInfo) == 0)
        #expect(parentInfo.st_mode & 0o777 == 0o555)
    }

    @Test
    func refusesImmutableDirectoryWithoutClearingFlags() throws {
        let fakeHome = URL(fileURLWithPath: "/private/tmp/DS-test-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let cache = fakeHome.appending(path: "Library/Caches/immutable-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appending(path: "keep.bin")
        try Data(repeating: 0x11, count: 256).write(to: file)
        #expect(chflags(cache.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(cache.path, 0) }

        let candidate = CleanupCandidate(
            url: cache,
            name: "Immutable cache",
            category: .cache,
            size: 256,
            risk: .low,
            reason: "Fixture",
            identity: try identity(of: cache),
            deletionMode: .contents
        )
        #expect(throws: SecureDeletionError.self) {
            try SecureFileDeleter.delete(candidate, entryRemoved: {})
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        var info = stat()
        #expect(lstat(cache.path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0)
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
