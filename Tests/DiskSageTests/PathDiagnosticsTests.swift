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
}
