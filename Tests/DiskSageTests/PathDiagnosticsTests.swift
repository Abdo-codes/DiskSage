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
}
