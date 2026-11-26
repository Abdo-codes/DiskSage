import Foundation
import Testing
@testable import DiskSage

struct ProjectCacheTests {
    private func initGitProject(at dir: URL, gitignore: String) throws {
        let git = WorktreeGitProcess()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try git.run(dir.path, ["init", "-b", "main"])
        _ = try git.run(dir.path, ["config", "user.name", "Test"])
        _ = try git.run(dir.path, ["config", "user.email", "test@example.com"])
        try Data(gitignore.utf8).write(to: dir.appending(path: ".gitignore"))
        _ = try git.run(dir.path, ["add", ".gitignore"])
        _ = try git.run(dir.path, ["commit", "-m", "Initial"])
    }

    @Test func offersGitIgnoredQuietCachesAndRespectsBesideMarkers() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let app = f.base.appending(path: "Developer/web-app")
        try initGitProject(at: app, gitignore: "node_modules/\ntarget/\ndist/\n")
        try f.write("Developer/web-app/package.json", bytes: 64)
        try f.write("Developer/web-app/node_modules/pkg/index.js", bytes: 8_192)
        try f.write("Developer/web-app/dist/bundle.js", bytes: 8_192)
        // `target` without Cargo.toml or pom.xml must not match.
        try f.write("Developer/web-app/target/debug/out", bytes: 8_192)

        // Too recent (12 hours < 24h quiet period): nothing offered.
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: f.later(hours: 12), home: f.base, minimumBytes: 1).isEmpty)

        let quietNow = f.later(hours: 30)
        let found = ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1)
        let expected = Set([
            CleanupPath.fileURL(app.appending(path: "node_modules")),
            CleanupPath.fileURL(app.appending(path: "dist")),
        ])
        #expect(Set(found.map(\.url)) == expected)
        #expect(found.allSatisfy { $0.deletionMode == .projectCache && $0.risk == .low && $0.category == .cache })

        // Verify SafetyPolicy, pre-deletion check, and full removal of the matched directory.
        for candidate in found {
            try SafetyPolicy(home: f.base, now: quietNow).validate(candidate)
            try ProjectCacheInventory.verifyBeforeDeletion(candidate, activity: .idle, now: quietNow, home: f.base)
            try SecureFileDeleter.delete(candidate, entryRemoved: {})
            #expect(!f.exists(candidate.url))
        }
        // Unmatched `target/` stays untouched.
        #expect(f.exists(app.appending(path: "target/debug/out")))
    }

    @Test func refusesTrackedFilesUnignoredCachesAndNestedGitRepos() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let app = f.base.appending(path: "Developer/rust-app")
        try initGitProject(at: app, gitignore: "target/\nnode_modules/\n")
        try f.write("Developer/rust-app/Cargo.toml", bytes: 64)
        try f.write("Developer/rust-app/target/debug/tracked.txt", bytes: 8_192)
        // Force-track a file inside ignored `target/`: must refuse `target/`.
        let git = WorktreeGitProcess()
        _ = try git.run(app.path, ["add", "-f", "target/debug/tracked.txt"])
        _ = try git.run(app.path, ["commit", "-m", "Track inside target"])

        // Unignored `.venv`: must refuse.
        try f.write("Developer/rust-app/.venv/lib/mod.py", bytes: 8_192)

        // Ignored `node_modules` holding a nested Git repo: must refuse.
        try f.write("Developer/rust-app/node_modules/some-dep/.git/HEAD", bytes: 64)
        try f.write("Developer/rust-app/node_modules/some-dep/index.js", bytes: 8_192)

        let found = ProjectCacheInventory.candidates(activity: .idle, now: f.later(hours: 30), home: f.base, minimumBytes: 1)
        #expect(found.isEmpty)
    }

    @Test func refuseInsideProtectsMixReleasesAndRebarSources() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let elixir = f.base.appending(path: "Developer/mix-app")
        try initGitProject(at: elixir, gitignore: "_build/\n")
        try f.write("Developer/mix-app/mix.exs", bytes: 64)
        try f.write("Developer/mix-app/_build/dev/lib/app/ebin/app.beam", bytes: 8_192)

        let quietNow = f.later(hours: 30)
        let offered = try #require(ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1).first)
        #expect(offered.url == CleanupPath.fileURL(elixir.appending(path: "_build")))

        // Adding a release under `_build/prod/rel` blocks both scanning and pre-deletion verification.
        try f.write("Developer/mix-app/_build/prod/rel/app/releases/COOKIE", bytes: 64)
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1).isEmpty)
        #expect(throws: (any Error).self) {
            try ProjectCacheInventory.verifyBeforeDeletion(offered, activity: .idle, now: quietNow, home: f.base)
        }
    }

    @Test func claudeTranscriptActivityAndRunningProcessesBlockCleanup() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let app = f.base.appending(path: "Developer/agent-app")
        try initGitProject(at: app, gitignore: "node_modules/\n")
        try f.write("Developer/agent-app/node_modules/a/index.js", bytes: 8_192)

        let quietNow = f.later(hours: 30)
        let claudeDir = try f.folder(".claude/projects")
        let encoded = ProjectCacheInventory.encodeClaudeFolder(CleanupPath.fileURL(app).path)
        let transcript = try f.write(".claude/projects/\(encoded)/session.jsonl", bytes: 128)
        // Move transcript mtime to 28 hours after start (only 2 hours before quietNow -> project is active!).
        let recentDate = f.later(hours: 28)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: transcript.path)

        #expect(ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1,
                                                 claudeProjectsDirectory: claudeDir).isEmpty)

        // Once the transcript is also older than 24 hours, the cache qualifies — unless a process uses it.
        let laterNow = f.later(hours: 60)
        let offered = try #require(ProjectCacheInventory.candidates(activity: .idle, now: laterNow, home: f.base,
                                                                    minimumBytes: 1, claudeProjectsDirectory: claudeDir).first)
        let busy = CleanupActivity(paths: [offered.url.appending(path: "a/index.js").path])
        #expect(ProjectCacheInventory.candidates(activity: busy, now: laterNow, home: f.base,
                                                 minimumBytes: 1, claudeProjectsDirectory: claudeDir).isEmpty)
        #expect(throws: (any Error).self) {
            try ProjectCacheInventory.verifyBeforeDeletion(offered, activity: busy, now: laterNow,
                                                           home: f.base, claudeProjectsDirectory: claudeDir)
        }
    }

    @Test func supportsMultiSegmentPathRulesLikeVendorBundleAndDotNetGlobs() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let ruby = f.base.appending(path: "Developer/rails-app")
        try initGitProject(at: ruby, gitignore: "vendor/bundle/\ntmp/cache/\n")
        try f.write("Developer/rails-app/Gemfile", bytes: 32)
        try f.write("Developer/rails-app/config.ru", bytes: 32)
        try f.write("Developer/rails-app/vendor/bundle/ruby/3.3/gems/a.rb", bytes: 8_192)
        try f.write("Developer/rails-app/tmp/cache/bootsnap/a.bin", bytes: 8_192)

        let dotnet = f.base.appending(path: "Developer/cs-app")
        try initGitProject(at: dotnet, gitignore: "bin/\nobj/\n")
        try f.write("Developer/cs-app/App.csproj", bytes: 32)
        try f.write("Developer/cs-app/bin/Debug/app.dll", bytes: 8_192)
        try f.write("Developer/cs-app/obj/Debug/app.pdb", bytes: 8_192)

        let found = ProjectCacheInventory.candidates(activity: .idle, now: f.later(hours: 30), home: f.base, minimumBytes: 1)
        let expected = Set([
            CleanupPath.fileURL(ruby.appending(path: "vendor/bundle")),
            CleanupPath.fileURL(ruby.appending(path: "tmp/cache")),
            CleanupPath.fileURL(dotnet.appending(path: "bin")),
            CleanupPath.fileURL(dotnet.appending(path: "obj")),
        ])
        #expect(Set(found.map(\.url)) == expected)
    }

    @Test func checksQuietPeriodAgainstEachCachesOwningNestedRepository() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let outer = f.base.appending(path: "Developer/mono")
        let inner = outer.appending(path: "packages/sub")
        try initGitProject(at: outer, gitignore: "node_modules/\npackages/sub/\n")
        try initGitProject(at: inner, gitignore: "node_modules/\n")
        try f.write("Developer/mono/node_modules/a/index.js", bytes: 8_192)
        try f.write("Developer/mono/packages/sub/node_modules/b/index.js", bytes: 8_192)

        let quietNow = f.later(hours: 30)
        // Make ONLY the nested repository active (2 hours before quietNow); outer stays quiet.
        let recent = f.later(hours: 28)
        let innerHeadLog = inner.appending(path: ".git/logs/HEAD")
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: innerHeadLog.path)

        let onlyOuter = ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1)
        #expect(onlyOuter.map(\.url) == [CleanupPath.fileURL(outer.appending(path: "node_modules"))])

        // Reverse: make outer active while inner becomes quiet (at 60h, outer touched at 58h).
        let laterNow = f.later(hours: 60)
        let outerHeadLog = outer.appending(path: ".git/logs/HEAD")
        try FileManager.default.setAttributes([.modificationDate: f.later(hours: 58)], ofItemAtPath: outerHeadLog.path)

        let onlyInner = ProjectCacheInventory.candidates(activity: .idle, now: laterNow, home: f.base, minimumBytes: 1)
        let innerCache = try #require(onlyInner.first)
        #expect(onlyInner.map(\.url) == [CleanupPath.fileURL(inner.appending(path: "node_modules"))])
        try ProjectCacheInventory.verifyBeforeDeletion(innerCache, activity: .idle, now: laterNow, home: f.base)
    }

    @Test func uncommittedTrackedEditsAndStagedIndexBlockCleanupAndCustomSkipExcludesDiscovery() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let git = WorktreeGitProcess()
        let app = f.base.appending(path: "Developer/active-work")
        try initGitProject(at: app, gitignore: "node_modules/\n")
        try f.write("Developer/active-work/package.json", bytes: 64)
        let tracked = try f.write("Developer/active-work/src/index.js", bytes: 32)
        _ = try git.run(app.path, ["add", "package.json", "src/index.js"])
        _ = try git.run(app.path, ["commit", "-m", "Add source"])
        try f.write("Developer/active-work/node_modules/pkg/index.js", bytes: 8_192)

        // Quiet at 30h normally.
        let quietNow = f.later(hours: 30)
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1).count == 1)

        // Uncommitted modification to a tracked file (mtime 28h) keeps project active at 30h even if logs/HEAD is old.
        try Data("console.log('wip');\n".utf8).write(to: tracked)
        try FileManager.default.setAttributes([.modificationDate: f.later(hours: 28)], ofItemAtPath: tracked.path)
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1).isEmpty)
        let diag = PathDiagnostics.explain(CleanupPath.fileURL(app.appending(path: "node_modules")).path,
                                           activity: .idle, now: quietNow, home: f.base, git: git, minimumProjectBytes: 1)
        #expect(diag.verdict == .skipped)
        #expect(diag.reasons.contains { $0.contains("quiet period") })

        // Revert tracked edit, backdate git metadata to start, then stage a new file so only .git/index is recent (28h).
        _ = try git.run(app.path, ["checkout", "--", "src/index.js"])
        let indexPath = app.appending(path: ".git/index").path
        try FileManager.default.setAttributes([.modificationDate: f.start], ofItemAtPath: app.appending(path: ".git/logs/HEAD").path)
        try FileManager.default.setAttributes([.modificationDate: f.start], ofItemAtPath: app.appending(path: ".git/HEAD").path)
        try FileManager.default.setAttributes([.modificationDate: f.start], ofItemAtPath: indexPath)
        let staged = try f.write("Developer/active-work/src/staged.js", bytes: 16)
        _ = try git.run(app.path, ["add", "src/staged.js"])
        try FileManager.default.setAttributes([.modificationDate: f.start], ofItemAtPath: staged.path)
        try FileManager.default.setAttributes([.modificationDate: f.later(hours: 28)], ofItemAtPath: indexPath)
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1).isEmpty)

        // Custom skip rule excludes entire directory subtrees during Git project discovery.
        let skippedRepo = f.base.appending(path: "Developer/archived/old-app")
        try initGitProject(at: skippedRepo, gitignore: "node_modules/\n")
        try f.write("Developer/archived/old-app/node_modules/pkg/index.js", bytes: 8_192)
        var customRules = ProjectCacheRules.default
        customRules.skip.insert("archived")
        let discovery = ProjectCacheInventory.discoverGitProjects(
            under: [f.base.appending(path: "Developer")], skip: customRules.skip, git: git
        )
        #expect(!discovery.projects.contains(CleanupPath.fileURL(skippedRepo)))

        // Reset clean state and verify projectLastActivity works from a subdirectory (`../.git/HEAD`)
        // and detects unstaged removal of a nested tracked directory (`rm -rf` ancestor unlink mtime).
        _ = try git.run(app.path, ["reset", "--hard"])
        _ = try git.run(app.path, ["clean", "-fd"])
        try f.write("Developer/active-work/nested/deep/file.js", bytes: 16)
        _ = try git.run(app.path, ["add", "nested/deep/file.js"])
        _ = try git.run(app.path, ["commit", "-m", "Add nested file"])
        for meta in [".git/logs/HEAD", ".git/HEAD", ".git/index"] {
            try FileManager.default.setAttributes([.modificationDate: f.start], ofItemAtPath: app.appending(path: meta).path)
        }
        let subdir = app.appending(path: "src")
        let subdirQuiet = try #require(ProjectCacheInventory.projectLastActivity(
            root: subdir,
            claudeDir: f.base.appending(path: ".claude/projects"),
            claudeFolders: [],
            now: quietNow,
            git: git
        ))
        #expect(abs(subdirQuiet.timeIntervalSince(f.start)) < 0.01)

        try FileManager.default.removeItem(at: app.appending(path: "nested"))
        try FileManager.default.setAttributes([.modificationDate: f.later(hours: 29)], ofItemAtPath: app.path)
        let afterRemovedSubdir = try #require(ProjectCacheInventory.projectLastActivity(
            root: subdir,
            claudeDir: f.base.appending(path: ".claude/projects"),
            claudeFolders: [],
            now: quietNow,
            git: git
        ))
        #expect(abs(afterRemovedSubdir.timeIntervalSince(f.later(hours: 29))) < 0.01)
    }

    @Test func refusesReposWithConfiguredGitCleanFiltersWithoutExecutingThem() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let git = WorktreeGitProcess()
        let app = f.base.appending(path: "Developer/filtered-app")
        try initGitProject(at: app, gitignore: "node_modules/\n")
        try Data("*.js filter=fixture\n".utf8).write(to: app.appending(path: ".gitattributes"))
        try f.write("Developer/filtered-app/package.json", bytes: 64)
        let tracked = try f.write("Developer/filtered-app/src/index.js", bytes: 32)
        _ = try git.run(app.path, ["add", ".gitattributes", "package.json", "src/index.js"])
        _ = try git.run(app.path, ["commit", "-m", "Add filtered source"])
        try f.write("Developer/filtered-app/node_modules/pkg/index.js", bytes: 8_192)

        let marker = f.base.appending(path: "clean-filter-ran")
        _ = try git.run(app.path, ["config", "filter.fixture.clean", "touch '\(marker.path)'"])

        // Touch a tracked file matching .gitattributes so an unguarded `git status` would invoke the clean filter.
        try Data("console.log('dirty');\n".utf8).write(to: tracked)
        for path in [
            tracked.path,
            app.appending(path: ".git/logs/HEAD").path,
            app.appending(path: ".git/HEAD").path,
            app.appending(path: ".git/index").path,
            app.appending(path: "node_modules").path,
        ] {
            try FileManager.default.setAttributes([.modificationDate: f.start], ofItemAtPath: path)
        }

        let quietNow = f.later(hours: 30)
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1).isEmpty)
        let diag = PathDiagnostics.explain(CleanupPath.fileURL(app.appending(path: "node_modules")).path,
                                           activity: .idle, now: quietNow, home: f.base, git: git, minimumProjectBytes: 1)
        #expect(diag.verdict == .skipped)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
