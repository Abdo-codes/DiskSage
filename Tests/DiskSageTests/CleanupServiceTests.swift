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

        let report = await CleanupService().delete([bad, good])

        #expect(report.items.count == 2)
        #expect(report.items.filter(\.succeeded).count == 1)
        #expect(report.items.filter { !$0.succeeded }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: removable.path))
        #expect(FileManager.default.fileExists(atPath: changed.path))
    }

    private func identity(of url: URL) throws -> FileIdentity {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
