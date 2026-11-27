import Foundation
import Testing
@testable import DiskSage

struct PathDiagnosticsTests {
    @Test func explainsKeepRulesSymlinksAndOutsideScopePaths() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".cargo/registry/cache/a.crate", bytes: 8_192)
        let cargo = CleanupPath.fileURL(f.base.appending(path: ".cargo/registry"))

        let kept = PathDiagnostics.explain(cargo.path, activity: .idle, now: f.later(hours: 2),
                                           home: f.base, keep: KeepRules(paths: [cargo.path]), minimumGlobalBytes: 1)
        #expect(kept.verdict == .skipped)
        #expect(kept.matcher == "Keep rules")

        let target = try f.folder("elsewhere")
        let link = f.base.appending(path: "symlink-cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let symlinked = PathDiagnostics.explain(link.path, activity: .idle, home: f.base)
        #expect(symlinked.verdict == .skipped)
        #expect(symlinked.matcher == "Symlink guard")

        let randomDir = try f.folder("Documents/notes")
        let outside = PathDiagnostics.explain(randomDir.path, activity: .idle, home: f.base)
        #expect(outside.verdict == .outsideScope)

        let relative = PathDiagnostics.explain("relative/path", activity: .idle, home: f.base)
        #expect(relative.verdict == .outsideScope)
    }

    @Test func explainsEcosystemCacheEligibilityAndBlockers() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".m2/repository/org/example/a/1.0/a.jar", bytes: 8_192)
        let repo = CleanupPath.fileURL(f.base.appending(path: ".m2/repository"))

        // Eligible after 2h idle.
        let ok = PathDiagnostics.explain(repo.path, activity: .idle, now: f.later(hours: 2),
                                         home: f.base, minimumGlobalBytes: 1)
        #expect(ok.verdict == .eligible)
        #expect(ok.risk == "low")

        // Blocked by maven-metadata-local.xml and running mvn command.
        try f.write(".m2/repository/org/example/a/maven-metadata-local.xml", bytes: 64)
        let blocked = PathDiagnostics.explain(repo.path, activity: CleanupActivity(paths: [], commands: ["mvn"]),
                                              now: f.later(hours: 2), home: f.base, minimumGlobalBytes: 1)
        #expect(blocked.verdict == .skipped)
        #expect(blocked.reasons.contains { $0.contains("maven-metadata-local.xml") })
        #expect(blocked.reasons.contains { $0.contains("mvn") })
    }

    @Test func explainsProjectCacheGuardsIncludingBesideMarkersTrackedFilesAndQuietPeriod() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let git = WorktreeGitProcess()
        let repo = try f.folder("Developer/demo")
        _ = try git.run(repo.path, ["init", "-q"])
        _ = try git.run(repo.path, ["config", "user.email", "test@example.com"])
        _ = try git.run(repo.path, ["config", "user.name", "Test"])
        try f.write("Developer/demo/.gitignore", bytes: 0)
        try Data("node_modules/\n".utf8).write(to: repo.appending(path: ".gitignore"))
        try Data("{\"name\":\"demo\"}".utf8).write(to: repo.appending(path: "package.json"))
        _ = try git.run(repo.path, ["add", ".gitignore", "package.json"])
        _ = try git.run(repo.path, ["commit", "-q", "-m", "init"])

        try f.write("Developer/demo/node_modules/pkg/index.js", bytes: 16_384)
        let modules = CleanupPath.fileURL(repo.appending(path: "node_modules"))

        // Active (just committed): skipped because of quiet period.
        let recent = PathDiagnostics.explain(modules.path, activity: .idle, now: f.later(hours: 1),
                                             home: f.base, git: git, minimumProjectBytes: 1)
        #expect(recent.verdict == .skipped)
        #expect(recent.reasons.contains { $0.contains("quiet period") })

        // Quiet (>24h): eligible!
        let quiet = PathDiagnostics.explain(modules.path, activity: .idle, now: f.later(hours: 30),
                                            home: f.base, git: git, minimumProjectBytes: 1)
        #expect(quiet.verdict == .eligible)
        #expect(quiet.risk == "low")

        // Force-tracked file inside node_modules: skipped with tracked-file reason.
        _ = try git.run(repo.path, ["add", "-f", "node_modules/pkg/index.js"])
        let tracked = PathDiagnostics.explain(modules.path, activity: .idle, now: f.later(hours: 30),
                                              home: f.base, git: git, minimumProjectBytes: 1)
        #expect(tracked.verdict == .skipped)
        #expect(tracked.reasons.contains { $0.contains("tracked") })

        // Missing beside marker (`build` without build.gradle / Cargo.toml / etc.).
        try f.write("Developer/demo/build/out.bin", bytes: 16_384)
        let missingMarker = PathDiagnostics.explain(CleanupPath.fileURL(repo.appending(path: "build")).path,
                                                    activity: .idle, now: f.later(hours: 30),
                                                    home: f.base, git: git, minimumProjectBytes: 1)
        #expect(missingMarker.verdict == .skipped)
        #expect(missingMarker.reasons.contains { $0.contains("markers") })
    }

    @Test func generatedBuildPathsBypassProjectCacheSkipListAndFallbackFromRecentWholeFolders() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        // `.build` is in ProjectCacheRules.default.skip, so explain must fall through to GeneratedCleanupScope.
        try f.write("Developer/swift-app/.build/debug/App.o", bytes: 8_192)
        let dotBuild = CleanupPath.fileURL(f.base.appending(path: "Developer/swift-app/.build"))
        let dotBuildDiag = PathDiagnostics.explain(dotBuild.path, activity: .idle, now: f.later(hours: 2), home: f.base)
        #expect(dotBuildDiag.verdict == .eligible)
        #expect(dotBuildDiag.matcher == "Generated files")

        // DerivedData inside ~/Developer/app is a `.derivedData` temporary build (too recent at 2h for whole-folder),
        // so explain must fall through to generated-file eligibility just like TemporaryBuildInspector.scan.
        try f.write("Developer/ios-app/DerivedData/Build/Intermediates.noindex/Main.o", bytes: 8_192)
        let derived = CleanupPath.fileURL(f.base.appending(path: "Developer/ios-app/DerivedData"))
        let derivedDiag = PathDiagnostics.explain(derived.path, activity: .idle, now: f.later(hours: 2), home: f.base)
        #expect(derivedDiag.verdict == .eligible)
        #expect(derivedDiag.matcher == "Generated files")

        // Custom-named `build` directory with Xcode output markers (and no Gradle/Python project markers beside it)
        // must fall through from project-cache missing-marker refusal to GeneratedCleanupScope eligibility.
        try f.write("Developer/xcode-custom/build/Build/Intermediates.noindex/App.o", bytes: 8_192)
        let customBuild = CleanupPath.fileURL(f.base.appending(path: "Developer/xcode-custom/build"))
        let customBuildDiag = PathDiagnostics.explain(customBuild.path, activity: .idle, now: f.later(hours: 2), home: f.base)
        #expect(customBuildDiag.verdict == .eligible)
        #expect(customBuildDiag.matcher == "Generated files")
    }

    @Test func liveClaudeSessionBlocksScratchpadEvenWhenScratchpadItselfIsOld() throws {
        let project = TemporaryBuildOutput.claudeRoot.appending(path: "disksage-diag-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        let session = project.appending(path: "session-1", directoryHint: .isDirectory)
        let scratchpad = session.appending(path: "scratchpad", directoryHint: .isDirectory)
        let tasks = session.appending(path: "tasks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratchpad, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)

        let oldFile = scratchpad.appending(path: "notes.txt")
        try Data(repeating: 1, count: 4_096).write(to: oldFile)
        let liveFile = tasks.appending(path: "active.log")
        try Data("active".utf8).write(to: liveFile)

        // Advance `now` by 10 days so scratchpad alone passes TemporaryBuildInspector.inspect,
        // while an active process holds a sibling file inside the same Claude session.
        let tenDaysLater = Date().addingTimeInterval(10 * 24 * 3_600)
        let activeSession = CleanupActivity(paths: [CleanupPath.fileURL(liveFile).path])
        #expect(TemporaryBuildInspector.inspect(scratchpad, activity: activeSession, now: tenDaysLater) != nil)

        let diag = PathDiagnostics.explain(scratchpad.path, activity: activeSession, now: tenDaysLater)
        #expect(diag.verdict == .skipped)
        #expect(diag.matcher == "Claude session guard")
    }

    @Test func explainsSimulatorRuntimeEligibilityAndSkipReasons() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let pUnusable = try f.folder("runtimes/unusable")
        let pUnused = try f.folder("runtimes/unused")
        let mUnused = try f.folder("mounts/unused")
        let pUsed = try f.folder("runtimes/used")
        let pRecent = try f.folder("runtimes/recent")
        let pNonDeletable = try f.folder("runtimes/nondeletable")
        let now = ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z")!
        let oldDate = ISO8601DateFormatter().date(from: "2026-11-10T10:00:00Z")!
        let recentDate = ISO8601DateFormatter().date(from: "2026-11-22T08:00:00Z")!

        let runtimes = [
            SimulatorRuntime(identifier: "11111111-AAAA-AAAA-AAAA-111111111111",
                             runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-old",
                             platformIdentifier: "com.apple.platform.iphonesimulator",
                             version: "27.2", build: "24B91016s", state: "Unusable", deletable: true,
                             sizeBytes: 8_300_000_000, path: pUnusable.path, mountPath: nil,
                             runtimeBundlePath: nil, lastUsedAt: recentDate),
            SimulatorRuntime(identifier: "22222222-BBBB-BBBB-BBBB-222222222222",
                             runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-0",
                             platformIdentifier: "com.apple.platform.watchsimulator",
                             version: "26.0", build: "23S100", state: "Ready", deletable: true,
                             sizeBytes: 3_800_000_000, path: pUnused.path, mountPath: mUnused.path,
                             runtimeBundlePath: nil, lastUsedAt: oldDate),
            SimulatorRuntime(identifier: "33333333-CCCC-CCCC-CCCC-333333333333",
                             runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                             platformIdentifier: "com.apple.platform.iphonesimulator",
                             version: "27.2", build: "24B114", state: "Ready", deletable: true,
                             sizeBytes: 8_300_000_000, path: pUsed.path, mountPath: nil,
                             runtimeBundlePath: nil, lastUsedAt: oldDate),
            SimulatorRuntime(identifier: "44444444-DDDD-DDDD-DDDD-444444444444",
                             runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-27-0",
                             platformIdentifier: "com.apple.platform.appletvsimulator",
                             version: "27.0", build: "24J10", state: "Ready", deletable: true,
                             sizeBytes: 4_000_000_000, path: pRecent.path, mountPath: nil,
                             runtimeBundlePath: nil, lastUsedAt: recentDate),
            SimulatorRuntime(identifier: "55555555-EEEE-EEEE-EEEE-555555555555",
                             runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.visionOS-27-0",
                             platformIdentifier: "com.apple.platform.xrsimulator",
                             version: "27.0", build: "24O10", state: "Ready", deletable: false,
                             sizeBytes: 9_000_000_000, path: pNonDeletable.path, mountPath: nil,
                             runtimeBundlePath: nil, lastUsedAt: oldDate),
        ]
        let devicesJSON = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[{"udid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"iPhone 17","state":"Shutdown","isAvailable":true}]}}
        """
        let simctl: SimulatorInventory.Run = { _ in (0, Data(devicesJSON.utf8)) }

        let unusableDiag = PathDiagnostics.explain(pUnusable.path, activity: .idle, now: now, home: f.base,
                                                   simctl: simctl, runtimes: runtimes)
        #expect(unusableDiag.verdict == .eligible)
        #expect(unusableDiag.risk == "medium")
        #expect(unusableDiag.sizeBytes == 8_300_000_000)

        let unusedDiag = PathDiagnostics.explain(pUnused.path, activity: .idle, now: now, home: f.base,
                                                 simctl: simctl, runtimes: runtimes)
        #expect(unusedDiag.verdict == .eligible)

        let keptUnusedDiag = PathDiagnostics.explain(pUnused.path, activity: .idle, now: now, home: f.base,
                                                     keep: KeepRules(simulatorNames: ["watchOS*"]),
                                                     simctl: simctl, runtimes: runtimes)
        #expect(keptUnusedDiag.verdict == .skipped)
        #expect(keptUnusedDiag.reasons.contains { $0.contains("Keep rule") })

        let usedDiag = PathDiagnostics.explain(pUsed.path, activity: .idle, now: now, home: f.base,
                                               simctl: simctl, runtimes: runtimes)
        #expect(usedDiag.verdict == .skipped)
        #expect(usedDiag.reasons.contains { $0.contains("configured simulator device") })

        let recentDiag = PathDiagnostics.explain(pRecent.path, activity: .idle, now: now, home: f.base,
                                                 simctl: simctl, runtimes: runtimes)
        #expect(recentDiag.verdict == .skipped)
        #expect(recentDiag.reasons.contains { $0.contains("24 hours") })

        let nonDeletableDiag = PathDiagnostics.explain(pNonDeletable.path, activity: .idle, now: now, home: f.base,
                                                       simctl: simctl, runtimes: runtimes)
        #expect(nonDeletableDiag.verdict == .skipped)
        #expect(nonDeletableDiag.reasons.contains { $0.contains("non-deletable") })

        let mountKeptDiag = PathDiagnostics.explain(mUnused.path, activity: .idle, now: now, home: f.base,
                                                    keep: KeepRules(paths: [pUnused.path]),
                                                    simctl: simctl, runtimes: runtimes)
        #expect(mountKeptDiag.verdict == .skipped)
        #expect(mountKeptDiag.reasons.contains { $0.contains("Keep rule") })
    }

    @Test func explainsEmptyAndRecentXcodeArchivesAccuratelyWithoutChangedAfterScanMessage() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let emptyArchive = try f.folder("Library/Developer/Xcode/Archives/2026-10-01/Empty.xcarchive")
        try Data().write(to: emptyArchive.appending(path: "Info.plist"))
        let emptyDiag = PathDiagnostics.explain(emptyArchive.path, activity: .idle, now: f.later(hours: 48), home: f.base)
        #expect(emptyDiag.verdict == .skipped)
        #expect(emptyDiag.reasons.contains { $0.contains("no reclaimable bytes") })
        #expect(!emptyDiag.reasons.contains { $0.contains("changed after the scan") })

        try f.write("Library/Developer/Xcode/Archives/2026-10-01/Fresh.xcarchive/Info.plist", bytes: 64)
        try f.write("Library/Developer/Xcode/Archives/2026-10-01/Fresh.xcarchive/Products/App.bin", bytes: 4_096)
        let freshArchive = f.base.appending(path: "Library/Developer/Xcode/Archives/2026-10-01/Fresh.xcarchive")
        let freshDiag = PathDiagnostics.explain(freshArchive.path, activity: .idle, now: f.later(hours: 2), home: f.base)
        #expect(freshDiag.verdict == .skipped)
        #expect(freshDiag.reasons.contains { $0.contains("modified too recently") })
        #expect(!freshDiag.reasons.contains { $0.contains("changed after the scan") })
        #expect((freshDiag.sizeBytes ?? 0) > 0)

        // Recent DerivedData project folder falling through to generated-file check preserves surveyed sizeBytes.
        let recentDD = try f.derivedData("Library/Developer/Xcode/DerivedData/RecentApp-abcdefghijklmnopqrstuvwxyzab")
        let recentDDDiag = PathDiagnostics.explain(recentDD.path, activity: .idle, now: f.later(hours: 0.2), home: f.base)
        #expect(recentDDDiag.verdict == .skipped)
        #expect((recentDDDiag.sizeBytes ?? 0) > 0)
    }

    @Test func explainsNestedExtraRootUnderSkippedDirectoryUsingDeepestRoot() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let nestedRoot = try f.folder("Developer/DerivedData/my-app")
        let cache = try f.folder("Developer/DerivedData/my-app/node_modules")
        try f.write("Developer/DerivedData/my-app/package.json", bytes: 32)
        try f.write("Developer/DerivedData/my-app/node_modules/pkg.bin", bytes: 2_048)
        let configURL = ProjectCacheRulesLoader.configURL(home: f.base)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try ProjectCacheRulesLoader.save(.init(extraRoots: [nestedRoot.path]), to: configURL, home: f.base)

        let diag = PathDiagnostics.explain(cache.path, activity: .idle, now: f.later(hours: 48), home: f.base,
                                           minimumProjectBytes: 1)
        #expect(!diag.reasons.contains { $0.contains("project-cache skip list") })
        #expect(diag.matcher.contains("Project cache"))
    }
}
