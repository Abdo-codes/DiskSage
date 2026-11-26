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

    @Test func manyPlainFilesDoNotStopTheSearchForALaterBuildFolder() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let base = f.home.appending(path: "Developer")
        let assets = base.appending(path: "aaa-assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for index in 0..<300 { try Data().write(to: assets.appending(path: "image-\(index).bin")) }
        let build = base.appending(path: "zzz-app/.build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        // The old walk counted every file against one small budget and stopped in the asset folder.
        let result = GeneratedBuildDiscovery(maximumEntries: 10_000, maximumDirectories: 50).discover(under: base)
        #expect(result.directories.map(\.path).contains(CleanupPath.fileURL(build).path))
        #expect(!result.limitReached)
    }

    @Test func reachedDiscoveryLimitIsReported() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        let base = f.home.appending(path: "Developer")
        for index in 0..<5 {
            try FileManager.default.createDirectory(at: base.appending(path: "folder-\(index)/nested"), withIntermediateDirectories: true)
            try Data().write(to: base.appending(path: "folder-\(index)/file.bin"))
        }
        #expect(GeneratedBuildDiscovery(maximumDirectories: 3).discover(under: base).limitReached)
        #expect(GeneratedBuildDiscovery(maximumEntries: 3).discover(under: base).limitReached)
        #expect(!GeneratedBuildDiscovery().discover(under: base).limitReached)
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

    @Test func recognizesBroadIDECachesAndExtraPlusMiseBuildRoots() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        for rel in [
            "Library/Application Support/Cursor/Cache",
            "Library/Application Support/Cursor/CachedData",
            "Library/Application Support/Windsurf/CachedExtensionVSIXs",
            "Library/Application Support/Antigravity/Cache",
            "Library/Application Support/Granola/GPUCache",
        ] {
            #expect(GeneratedCleanupScope.rule(for: f.home.appending(path: rel), home: f.home) == .browserCache)
        }
        #expect(GeneratedCleanupScope.rule(
            for: f.home.appending(path: "Library/Application Support/Claude-Work/Cache"),
            home: f.home
        ) == nil)
        #expect(GeneratedCleanupScope.rule(
            for: URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/agent-device/apple/macos-helper/DerivedData"),
            home: f.home
        ) == nil)

        // Configure extra_roots and a mise tracked project outside ~/Developer.
        let extraRoot = f.home.appending(path: "Work/custom-workspace", directoryHint: .isDirectory)
        let extraBuild = extraRoot.appending(path: "App/.build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extraBuild, withIntermediateDirectories: true)
        let configURL = ProjectCacheRulesLoader.configURL(home: f.home, env: [:])
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectCacheRulesLoader.UserConfig(extraRoots: ["~/Work/custom-workspace"])).write(to: configURL)

        let miseProject = f.home.appending(path: "Tools/mise-app", directoryHint: .isDirectory)
        let miseBuild = miseProject.appending(path: ".build", directoryHint: .isDirectory)
        let miseConfig = miseProject.appending(path: "mise.toml")
        try FileManager.default.createDirectory(at: miseBuild, withIntermediateDirectories: true)
        try Data("[tools]\n".utf8).write(to: miseConfig)
        let miseEnv = MiseProjectDiscovery.Environment(home: f.home)
        try FileManager.default.createDirectory(at: miseEnv.trackedConfigsDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: miseEnv.trackedConfigsDir.appending(path: "mise-app"), withDestinationURL: miseConfig)

        let roots = Set(GeneratedCleanupScope.discoveryRoots(home: f.home, miseEnv: miseEnv))
        #expect(roots.contains(CleanupPath.fileURL(extraRoot)))
        #expect(roots.contains(CleanupPath.fileURL(miseProject)))
        #expect(GeneratedCleanupScope.rule(for: extraBuild, home: f.home, miseEnv: miseEnv) == .buildArtifacts)
        #expect(GeneratedCleanupScope.rule(for: miseBuild, home: f.home, miseEnv: miseEnv) == .buildArtifacts)
        #expect(Set(GeneratedBuildDiscovery().directories(under: extraRoot)) == [CleanupPath.fileURL(extraBuild)])
    }
}
