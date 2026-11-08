import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DiskSage

struct GeneratedCleanupTests {
    @Test func mixedBuildTreeDeletesOnlyGeneratedOutputs() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let generated = ["arm64/debug/App.build/a.o", "ModuleCache.noindex/a.pcm", "Index.noindex/v5/records/a"]
        let protected = ["checkouts/package/debug/input.a", "prebuilts/swift-syntax/SwiftSyntax.swiftmodule",
            "prebuilts/swift-syntax/libSwiftDiagnostics.a", "artifacts/framework/release/input.a",
            "source/a.swift", "snapshots/a.png", "testlogs/run.log", "Logs/Test/run.xcresult/a.o",
            "debug/a.dSYM/a.o", "debug/a.app/a.o", "debug/sessiondata.img", "debug/main.swift",
            "debug/trace.profraw", "debug/metadata.json", "debug/fixture.swiftinterface", "unclassified.a",
            "debug/a.xcarchive/file.o", "debug/evidence/file.o", "debug/.git/file.o"]
        for path in generated + protected { try f.write(path) }
        let target = try #require(try f.candidate())
        #expect(target.generatedSnapshot?.fileCount == generated.count)
        #expect(target.size == Int64(generated.count * 4_096))
        try f.delete(target)
        #expect(generated.allSatisfy { !f.exists($0) })
        #expect(protected.allSatisfy(f.exists))
        #expect(FileManager.default.fileExists(atPath: f.root.path))
    }

    @Test func recentFilesAndHardlinkedInputsAreExcluded() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let file = try f.write("debug/current.o")
        let recent = try GeneratedFileDeleter.inspect(f.root, name: "Recent", category: .build,
            rule: .buildArtifacts, activity: .idle)
        #expect(recent == nil)
        try FileManager.default.linkItem(at: file, to: f.home.appending(path: "shared-input.a"))
        #expect(try f.candidate() == nil)
    }

    @Test func goObjectsAreRecognizedByContentAndTestOutputStays() throws {
        let f = try GeneratedCleanupFixture(relative: "Library/Caches/go-build"); defer { f.remove() }
        let object = "aa/" + String(repeating: "a", count: 64) + "-d"
        let testLog = "bb/" + String(repeating: "b", count: 64) + "-d"
        let metadata = "cc/" + String(repeating: "c", count: 64) + "-a"
        try f.write(object, data: Data("!<arch>\ncompiled".utf8))
        try f.write(testLog, data: Data("# test log\ntest evidence".utf8))
        try f.write(metadata)
        let target = try #require(try f.candidate(rule: .goBuild))
        #expect(target.generatedSnapshot?.fileCount == 1)
        try f.delete(target)
        #expect(!f.exists(object) && f.exists(testLog) && f.exists(metadata))
    }

    @Test func npmKeepsIndexAndNonContentFiles() throws {
        let f = try GeneratedCleanupFixture(relative: ".npm/_cacache"); defer { f.remove() }
        try f.write("content-v2/sha512/aa/bb/opaque")
        try f.write("index-v5/aa/index")
        try f.write("content-v2/sha512/aa/bb/sessiondata.img")
        let target = try #require(try f.candidate(rule: .npmContent))
        #expect(target.generatedSnapshot?.fileCount == 1)
        try f.delete(target)
        #expect(f.exists("index-v5/aa/index") && f.exists("content-v2/sha512/aa/bb/sessiondata.img"))
    }

    @Test func bazelRequiresMatchingContentHash() throws {
        let data = Data("archive".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try GeneratedCleanupPolicy.eligible(name: "file", parents: [hash], rootName: "sha256",
            rule: .bazelArchives, prefix: { data }, checksum: { hash }))
        #expect(try !GeneratedCleanupPolicy.eligible(name: "file", parents: [String(repeating: "0", count: 64)],
            rootName: "sha256", rule: .bazelArchives, prefix: { data }, checksum: { hash }))
    }

    @Test(arguments: ["modified", "added", "replaced"])
    func changedInventoryRefusesEntireTarget(scenario: String) throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let first = try f.write("debug/a.o")
        try f.write("debug/b.o")
        let target = try #require(try f.candidate())
        switch scenario {
        case "modified": try Data("changed".utf8).write(to: first)
        case "added": try f.write("debug/c.o")
        default:
            try FileManager.default.moveItem(at: first, to: f.home.appending(path: "old"))
            try f.write("debug/a.o")
        }
        #expect(throws: (any Error).self) { try f.delete(target) }
        #expect(f.exists("debug/a.o") && f.exists("debug/b.o"))
    }

    @Test func activityBeforeDeletionAndFailedActivityScanRefuseCleanup() async throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let file = try f.write("debug/a.o")
        let target = try #require(try f.candidate())
        #expect(throws: FeatureFailure.self) {
            try GeneratedFileDeleter.delete(target, policy: f.policy,
                activity: { CleanupActivity(paths: [file.path]) }, entryRemoved: {})
        }
        #expect(f.exists("debug/a.o"))
        let results = await DiskScanner(locations: [], activity: { throw FeatureFailure(message: "unavailable") }).scan()
        #expect(results.isEmpty)
        #expect(CleanupActivity(paths: [], commands: ["go"]).contains(f.root, rule: .goBuild))
    }

    @Test func symlinksAreNeverFollowedAndParentSwapIsRefused() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let outside = f.home.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let keep = outside.appending(path: "a.o")
        try Data("keep".utf8).write(to: keep)
        try FileManager.default.createSymbolicLink(at: f.root.appending(path: "linked"), withDestinationURL: outside)
        try f.write("debug/a.o")
        let target = try #require(try f.candidate())
        #expect(target.generatedSnapshot?.fileCount == 1)
        #expect(throws: (any Error).self) {
            try f.delete(target, before: { _ in
                try FileManager.default.moveItem(at: f.root.appending(path: "debug"), to: f.root.appending(path: "saved"))
                try FileManager.default.createSymbolicLink(at: f.root.appending(path: "debug"), withDestinationURL: outside)
            })
        }
        #expect(try Data(contentsOf: keep) == Data("keep".utf8))
    }

    @Test func partialFailureReportsOnlyRemovedFiles() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o")
        let target = try #require(try f.candidate())
        do {
            try f.delete(target, before: { index in
                if index == 1 { try f.write("debug/b.o", data: Data("changed".utf8)) }
            })
            Issue.record("Expected partial failure")
        } catch let error as PartialCleanupFailure {
            #expect(error.removedFiles == 1 && error.removedBytes == 4_096)
        }
        #expect(!f.exists("debug/a.o") && f.exists("debug/b.o"))
    }

    @Test func ownedReadOnlyDirectoryPermissionsAreRestored() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o")
        let parent = f.root.appending(path: "debug")
        #expect(chmod(parent.path, 0o555) == 0)
        defer { chmod(parent.path, 0o755) }
        let target = try #require(try f.candidate())
        try f.delete(target)
        var info = stat(); #expect(lstat(parent.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o555)
        #expect(!f.exists("debug/a.o"))
    }

    @Test func inventoryLimitFailsClosed() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o")
        #expect(throws: FeatureFailure.self) {
            try GeneratedFileInventory.read(f.root, rule: .buildArtifacts, cutoff: f.cutoff, maximumEntries: 1)
        }
    }
}
