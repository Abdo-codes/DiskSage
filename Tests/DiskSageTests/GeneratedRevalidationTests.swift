import Foundation
import Testing
@testable import DiskSage

struct GeneratedRevalidationTests {
    private func deleteKeepingResult(_ f: GeneratedCleanupFixture, _ target: CleanupCandidate) throws -> CleanupRemoval {
        try GeneratedFileDeleter.delete(target, policy: f.policy, activity: { .idle }, entryRemoved: {})
    }

    @Test func aChangedFileStaysAndTheUnchangedFilesGo() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o"); try f.write("debug/c.o")
        let target = try #require(try f.candidate())
        #expect(target.generatedSnapshot?.entryFingerprints?.count == 3 * 8)
        try f.write("debug/b.o", data: Data(repeating: 7, count: 8_192))
        let removal = try deleteKeepingResult(f, target)
        #expect(removal.removedBytes == 8_192 && removal.skippedFiles == 1 && removal.note != nil)
        #expect(!f.exists("debug/a.o") && f.exists("debug/b.o") && !f.exists("debug/c.o"))
    }

    @Test func aNewFileAfterTheScanStays() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o")
        let target = try #require(try f.candidate())
        try f.write("debug/new.o")
        let removal = try deleteKeepingResult(f, target)
        #expect(removal.removedBytes == 4_096 && removal.skippedFiles == 0)
        #expect(!f.exists("debug/a.o") && f.exists("debug/new.o"))
    }

    @Test func aFileRemovedAfterTheScanDoesNotStopTheOthers() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o")
        let target = try #require(try f.candidate())
        try FileManager.default.removeItem(at: f.root.appending(path: "debug/a.o"))
        let removal = try deleteKeepingResult(f, target)
        #expect(removal.removedBytes == 4_096 && removal.skippedFiles == 1)
        #expect(!f.exists("debug/b.o"))
    }

    @Test func anOldSnapshotWithoutFingerprintsStaysStrict() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o")
        let scanned = try #require(try f.candidate())
        // Encode and remove the new field, as an older build would have stored it.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(scanned)) as? [String: Any])
        var snapshot = try #require(json["generatedSnapshot"] as? [String: Any])
        snapshot.removeValue(forKey: "entryFingerprints")
        json["generatedSnapshot"] = snapshot
        let target = try JSONDecoder().decode(CleanupCandidate.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(target.generatedSnapshot?.entryFingerprints == nil && target.generatedSnapshot?.fileCount == 2)
        try f.write("debug/b.o", data: Data(repeating: 7, count: 8_192))
        #expect(throws: SecureDeletionError.self) { try f.delete(target) }
        #expect(f.exists("debug/a.o") && f.exists("debug/b.o"))
    }

    @Test func allFilesChangedStillFails() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o")
        let target = try #require(try f.candidate())
        try f.write("debug/a.o", data: Data(repeating: 7, count: 8_192))
        try f.write("debug/b.o", data: Data(repeating: 7, count: 8_192))
        #expect(throws: SecureDeletionError.self) { try f.delete(target) }
        #expect(f.exists("debug/a.o") && f.exists("debug/b.o"))
    }

    @Test func fingerprintsThatDoNotMatchTheFileCountStayStrict() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o")
        let scanned = try #require(try f.candidate())
        let original = try #require(scanned.generatedSnapshot)
        let broken = GeneratedCleanupSnapshot(rule: original.rule, cutoff: original.cutoff, digest: original.digest,
            fileCount: original.fileCount, entryFingerprints: original.entryFingerprints?.prefix(8))
        let target = CleanupCandidate(url: scanned.url, name: scanned.name, category: scanned.category, size: scanned.size,
            risk: scanned.risk, reason: scanned.reason, identity: scanned.identity, deletionMode: .generatedFiles,
            generatedSnapshot: broken)
        try f.write("debug/b.o", data: Data(repeating: 7, count: 8_192))
        #expect(throws: SecureDeletionError.self) { try f.delete(target) }
        #expect(f.exists("debug/a.o"))
    }

    @Test func theSchedulerReportsRealBytesAsASuccess() async throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o")
        let target = try #require(try f.candidate())
        try f.write("debug/b.o", data: Data(repeating: 7, count: 8_192))
        let service = CleanupService(logger: CleanupLogger(directory: f.home.appending(path: "logs")), remove: { _, removed in
            try GeneratedFileDeleter.delete(target, policy: f.policy, activity: { .idle }, entryRemoved: removed)
        })
        let report = await service.delete([target], trigger: .manual, progress: { _ in })
        #expect(report.failures.isEmpty && report.removedEntryCount == 1)
        #expect(report.estimatedRemovedBytes == 4_096 && target.size == 8_192)
        #expect(report.items.first?.note == "Kept 1 file that changed after the scan.")
        #expect(!f.exists("debug/a.o") && f.exists("debug/b.o"))
    }
}
