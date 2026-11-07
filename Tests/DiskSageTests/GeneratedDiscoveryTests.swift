import Foundation
import Testing
@testable import DiskSage

struct GeneratedDiscoveryTests {
    @Test func discoversNestedBuildRootsButPrunesPreservedContainersAndLinks() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let base = f.home.appending(path: "Developer")
        let keep = ["Project/.build", "Worktrees/deep/app/DerivedData", "temp-build/Build/Intermediates.noindex"]
        let excluded = ["source-snapshots/repo/.build", "outputs/repo/.build", "repo/checkouts/dependency/.build",
                        "repo/prebuilts/tool/.build", "repo/test-results/DerivedData"]
        for path in keep + excluded {
            try FileManager.default.createDirectory(at: base.appending(path: path), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: base.appending(path: "alias"), withDestinationURL: f.root)
        let result = Set(GeneratedBuildDiscovery().directories(under: base).map(\.path))
        #expect(result == Set(["Project/.build", "Worktrees/deep/app/DerivedData", "temp-build"].map { base.appending(path: $0).path }))
        #expect(GeneratedBuildDiscovery(maximumEntries: 0).directories(under: base).isEmpty)
    }

    @Test func scopeRecognizesOnlyCuratedCacheLeavesAndGeneratedRoots() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let recognized = [(".npm/_cacache", GeneratedCleanupRule.npmContent),
            ("Library/Caches/go-build", .goBuild), ("Library/Application Support/Claude/Code Cache", .browserCache),
            ("Documents/Codex/chat/work/.build", .buildArtifacts)]
        for (relative, rule) in recognized {
            #expect(GeneratedCleanupScope.rule(for: f.home.appending(path: relative), home: f.home) == rule)
        }
        for relative in ["Library/Caches/Unknown", "Library/Application Support/Claude/IndexedDB",
                         "Developer/snapshots/.build", "Developer/repo/prebuilts/.build",
                         "Library/Developer/CoreSimulator/Devices", "Library/Developer/Xcode/iOS DeviceSupport"] {
            #expect(GeneratedCleanupScope.rule(for: f.home.appending(path: relative), home: f.home) == nil)
        }
    }

    @Test func snapshotAuthorizationCannotWidenScopeOrReduceAge() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o")
        let target = try #require(try f.candidate())
        for snapshot in [
            GeneratedCleanupSnapshot(rule: .npmContent, cutoff: f.cutoff, digest: String(repeating: "a", count: 64), fileCount: 1),
            .init(rule: .buildArtifacts, cutoff: f.now, digest: String(repeating: "a", count: 64), fileCount: 1),
            .init(rule: .buildArtifacts, cutoff: f.cutoff, digest: "invalid", fileCount: 1),
            .init(rule: .buildArtifacts, cutoff: f.cutoff, digest: String(repeating: "a", count: 64), fileCount: 0)
        ] {
            let invalid = CleanupCandidate(url: target.url, name: target.name, category: .build, size: target.size,
                risk: .low, reason: "Invalid", identity: target.identity, deletionMode: .generatedFiles, generatedSnapshot: snapshot)
            #expect(throws: SafetyPolicyError.self) { try f.policy.validate(invalid) }
        }
        let encoded = try JSONEncoder().encode(target)
        #expect(try JSONDecoder().decode(CleanupCandidate.self, from: encoded) == target)
        let legacy = CleanupCandidate(url: f.root, name: "Old", category: .build, size: 1, risk: .low, reason: "Old data")
        #expect(try JSONDecoder().decode(CleanupCandidate.self, from: JSONEncoder().encode(legacy)).generatedSnapshot == nil)
    }

    @Test func schedulerAndReportKeepPartialRemovalAccounting() async throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("debug/a.o"); try f.write("debug/b.o")
        let target = try #require(try f.candidate())
        let service = CleanupService(logger: CleanupLogger(directory: f.home.appending(path: "logs")), remove: { _, removed in
            try GeneratedFileDeleter.delete(target, policy: f.policy, activity: { .idle }, beforeEntry: { index in
                if index == 1 { throw FeatureFailure(message: "Injected failure") }
            }, entryRemoved: removed)
        })
        let report = await service.delete([target], trigger: .manual, progress: { _ in })
        #expect(report.failures.count == 1 && report.removedEntryCount == 1)
        #expect(report.estimatedRemovedBytes == 4_096 && report.items.first?.removedBytes == 4_096)
        #expect(!f.exists("debug/a.o") && f.exists("debug/b.o"))
    }
}
