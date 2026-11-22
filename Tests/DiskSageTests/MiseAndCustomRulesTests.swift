import Darwin
import Foundation
import Testing
@testable import DiskSage

struct MiseAndCustomRulesTests {
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

    @Test func discoversMiseTrackedProjectsAndSkipsGlobalConfigs() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let appConfig = try f.write("code/my-app/mise.toml", bytes: 32)
        let nestedConfig = try f.write("code/other/.config/mise/conf.d/tools.toml", bytes: 32)
        let globalConfig = try f.write(".config/mise/config.toml", bytes: 32)
        let homeConfig = try f.write(".tool-versions", bytes: 32)

        let tracked = try f.folder(".local/state/mise/tracked-configs")
        try FileManager.default.createSymbolicLink(at: tracked.appending(path: "1"), withDestinationURL: appConfig)
        try FileManager.default.createSymbolicLink(at: tracked.appending(path: "2"), withDestinationURL: nestedConfig)
        try FileManager.default.createSymbolicLink(at: tracked.appending(path: "3"), withDestinationURL: globalConfig)
        try FileManager.default.createSymbolicLink(at: tracked.appending(path: "4"), withDestinationURL: homeConfig)
        try FileManager.default.createSymbolicLink(at: tracked.appending(path: "broken"),
                                                   withDestinationURL: f.base.appending(path: "missing/mise.toml"))

        let env = MiseProjectDiscovery.Environment(home: CleanupPath.fileURL(f.base))
        let discovered = MiseProjectDiscovery.projectRoots(home: f.base, env: env)
        let expected = [
            CleanupPath.fileURL(f.base.appending(path: "code/my-app")),
            CleanupPath.fileURL(f.base.appending(path: "code/other")),
        ]
        #expect(discovered == expected)
    }

    @Test func scansMiseTrackedProjectOutsideDeveloperFolder() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let project = f.base.appending(path: "code/side-project")
        try initGitProject(at: project, gitignore: "node_modules/\n")
        let miseToml = try f.write("code/side-project/mise.toml", bytes: 32)
        try f.write("code/side-project/node_modules/pkg/index.js", bytes: 8_192)
        let tracked = try f.folder(".local/state/mise/tracked-configs")
        try FileManager.default.createSymbolicLink(at: tracked.appending(path: "side"), withDestinationURL: miseToml)

        let env = MiseProjectDiscovery.Environment(home: CleanupPath.fileURL(f.base))
        let quietNow = f.later(hours: 30)
        let found = ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base,
                                                     minimumBytes: 1, miseEnv: env)
        #expect(found.map(\.url) == [CleanupPath.fileURL(project.appending(path: "node_modules"))])
    }

    @Test func loadsCustomRulesAndRejectsUnsafeOverrides() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let rulesFile = f.base.appending(path: ".config/disksage/rules.json")
        try FileManager.default.createDirectory(at: rulesFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Missing file returns defaults.
        #expect(try ProjectCacheRulesLoader.load(from: rulesFile) == .default)

        // Valid custom rule merges names, beside, refuse_inside, skip, and quiet_hours.
        let validJSON = """
        {
          "names": [".build-cache"],
          "beside": { ".build-cache": ["build.toml"] },
          "refuse_inside": { ".build-cache": ["keep/*"] },
          "skip": ["third_party"],
          "quiet_hours": 48
        }
        """
        try Data(validJSON.utf8).write(to: rulesFile)
        let loaded = try ProjectCacheRulesLoader.load(from: rulesFile)
        #expect(loaded.names.contains(".build-cache"))
        #expect(loaded.beside[".build-cache"] == ["build.toml"])
        #expect(loaded.refuseInside[".build-cache"] == ["keep/*"])
        #expect(loaded.skip.contains("third_party"))
        #expect(loaded.quietHours == 48)

        // Custom rule works end-to-end with Git verification and quiet_hours.
        let app = f.base.appending(path: "Developer/custom-app")
        try initGitProject(at: app, gitignore: ".build-cache/\n")
        try f.write("Developer/custom-app/build.toml", bytes: 32)
        try f.write("Developer/custom-app/.build-cache/out.bin", bytes: 8_192)
        // 30 hours is under the custom 48-hour quiet period -> skipped.
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: f.later(hours: 30), home: f.base,
                                                 rules: loaded, minimumBytes: 1).isEmpty)
        // 60 hours -> offered!
        let offered = try #require(ProjectCacheInventory.candidates(activity: .idle, now: f.later(hours: 60),
                                                                    home: f.base, rules: loaded, minimumBytes: 1).first)
        #expect(offered.url == CleanupPath.fileURL(app.appending(path: ".build-cache")))

        // Protected refuse_inside entry blocks it.
        try f.write("Developer/custom-app/.build-cache/keep/important.dat", bytes: 64)
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: f.later(hours: 60), home: f.base,
                                                 rules: loaded, minimumBytes: 1).isEmpty)

        // Rejects VCS directory names and sub-hour quiet_hours.
        try Data(#"{"names": [".git"]}"#.utf8).write(to: rulesFile)
        #expect(throws: (any Error).self) { _ = try ProjectCacheRulesLoader.load(from: rulesFile) }

        try Data(#"{"quiet_hours": 0}"#.utf8).write(to: rulesFile)
        #expect(throws: (any Error).self) { _ = try ProjectCacheRulesLoader.load(from: rulesFile) }
    }

    @Test func customRefuseInsidePreservesBuiltInProtectionsAndCustomSkipExcludesCaches() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let rulesFile = f.base.appending(path: ".config/disksage/rules.json")
        try FileManager.default.createDirectory(at: rulesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {
          "refuse_inside": { "_build": ["custom/*"] },
          "skip": ["node_modules"]
        }
        """
        try Data(json.utf8).write(to: rulesFile)
        let loaded = try ProjectCacheRulesLoader.load(from: rulesFile)

        // Built-in Mix release protections remain alongside the added custom pattern.
        let buildProtections = Set(loaded.refuseInside["_build"] ?? [])
        #expect(buildProtections.isSuperset(of: ["*/rel", "*/lib/*/src", "custom/*"]))

        let app = f.base.appending(path: "Developer/mix-js-app")
        try initGitProject(at: app, gitignore: "_build/\nnode_modules/\n")
        try f.write("Developer/mix-js-app/mix.exs", bytes: 32)
        try f.write("Developer/mix-js-app/_build/prod/rel/app/COOKIE", bytes: 64)
        try f.write("Developer/mix-js-app/node_modules/pkg/index.js", bytes: 8_192)

        let quietNow = f.later(hours: 30)
        // Both `_build` (built-in `*/rel` protection preserved) and `node_modules` (custom skip) are excluded.
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base,
                                                 rules: loaded, minimumBytes: 1).isEmpty)
        #expect(!ProjectCacheInventory.isAllowedScope(app.appending(path: "node_modules"), home: f.base, rules: loaded))
    }

    @Test func retainsDeepMiseTrackedProjectsBeyondAncestorDiscoveryDepth() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        // 7 directory levels below ~/Developer (deeper than discoveryDepthLimit == 5).
        let deepRel = "Developer/l1/l2/l3/l4/l5/l6/deep-app"
        let deepProject = f.base.appending(path: deepRel)
        try initGitProject(at: deepProject, gitignore: "node_modules/\n")
        let miseToml = try f.write("\(deepRel)/mise.toml", bytes: 32)
        try f.write("\(deepRel)/node_modules/pkg/index.js", bytes: 8_192)
        let tracked = try f.folder(".local/state/mise/tracked-configs")
        try FileManager.default.createSymbolicLink(at: tracked.appending(path: "deep"), withDestinationURL: miseToml)

        let env = MiseProjectDiscovery.Environment(home: CleanupPath.fileURL(f.base))
        let quietNow = f.later(hours: 30)
        let found = ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base,
                                                     minimumBytes: 1, miseEnv: env)
        #expect(found.map(\.url) == [CleanupPath.fileURL(deepProject.appending(path: "node_modules"))])
    }

    @Test func resolvesOwningRepoForNestedMiseSubdirectoryWithoutWideningScope() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let monorepo = f.base.appending(path: "code/monorepo")
        try initGitProject(at: monorepo, gitignore: "node_modules/\n")
        // Only the `frontend` subdirectory has a tracked mise.toml; `.git` lives at `monorepo/.git`.
        let frontendConfig = try f.write("code/monorepo/frontend/mise.toml", bytes: 32)
        try f.write("code/monorepo/frontend/node_modules/pkg/index.js", bytes: 8_192)
        try f.write("code/monorepo/backend/node_modules/pkg/index.js", bytes: 8_192)
        let tracked = try f.folder(".local/state/mise/tracked-configs")
        try FileManager.default.createSymbolicLink(at: tracked.appending(path: "fe"), withDestinationURL: frontendConfig)

        let env = MiseProjectDiscovery.Environment(home: CleanupPath.fileURL(f.base))
        let quietNow = f.later(hours: 30)
        let found = ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base,
                                                     minimumBytes: 1, miseEnv: env)
        // Only the mise-tracked `frontend` cache is offered; untracked sibling `backend` stays untouched.
        let frontendCache = try #require(found.first)
        #expect(found.map(\.url) == [CleanupPath.fileURL(monorepo.appending(path: "frontend/node_modules"))])
        try ProjectCacheInventory.verifyBeforeDeletion(frontendCache, activity: .idle, now: quietNow, home: f.base)
    }

    @Test func savesAndLoadsExtraProjectRootsPreservingHandEditedFieldsAndRejectingUnsafeRoots() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let rulesFile = f.base.appending(path: ".config/disksage/rules.json")
        let projects = f.base.appending(path: "Projects/web-app")
        try initGitProject(at: projects, gitignore: "node_modules/\n")
        try f.write("Projects/web-app/node_modules/pkg/index.js", bytes: 8_192)

        // Start with hand-edited beside & refuse_inside rules; saving updated quiet_hours + extra_roots preserves them.
        var config = ProjectCacheRulesLoader.UserConfig(
            names: [".custom-out"],
            beside: [".custom-out": ["Makefile"]],
            refuseInside: [".custom-out": ["keep/*"]],
            skip: ["archive"],
            quietHours: 36,
            extraRoots: ["~/Projects"]
        )
        try ProjectCacheRulesLoader.save(config, to: rulesFile, home: f.base)

        let reread = try ProjectCacheRulesLoader.loadConfig(from: rulesFile)
        #expect(reread == config)
        let extra = ProjectCacheRulesLoader.extraRoots(home: f.base, env: ["XDG_CONFIG_HOME": f.base.appending(path: ".config").path])
        #expect(extra == [CleanupPath.fileURL(f.base.appending(path: "Projects"))])

        // End-to-end scan using ~/Projects via extra_roots in rules.json.
        let quietNow = f.later(hours: 40)
        let found = ProjectCacheInventory.candidates(activity: .idle, now: quietNow, home: f.base, minimumBytes: 1)
        let candidate = try #require(found.first)
        #expect(candidate.url == CleanupPath.fileURL(projects.appending(path: "node_modules")))
        try SafetyPolicy(home: f.base, now: quietNow).validate(candidate)
        try ProjectCacheInventory.verifyBeforeDeletion(candidate, activity: .idle, now: quietNow, home: f.base)

        // Unsafe extra_roots are rejected on save and reported by invalidExtraRoots.
        let unsafe = ["/", "~", "~/Library", "~/Library/Caches", "/etc", "~/Projects/.git", "relative/dir"]
        #expect(ProjectCacheRulesLoader.invalidExtraRoots(unsafe, home: f.base) == unsafe)
        for bad in unsafe {
            config.extraRoots = [bad]
            #expect(throws: (any Error).self) {
                try ProjectCacheRulesLoader.save(config, to: rulesFile, home: f.base)
            }
        }

        // Symlinked extra root is rejected.
        let external = try f.folder("external")
        let link = f.base.appending(path: "LinkedProjects")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        config.extraRoots = ["~/LinkedProjects"]
        #expect(throws: (any Error).self) {
            try ProjectCacheRulesLoader.save(config, to: rulesFile, home: f.base)
        }

        // Symlinked rules.json is refused on save.
        let realTarget = try f.write("elsewhere.json", bytes: 2)
        let linkRules = f.base.appending(path: "link-rules.json")
        try FileManager.default.createSymbolicLink(at: linkRules, withDestinationURL: realTarget)
        config.extraRoots = ["~/Projects"]
        #expect(throws: (any Error).self) {
            try ProjectCacheRulesLoader.save(config, to: linkRules, home: f.base)
        }
    }

    @Test func editableQuietHoursRejectsOutOfRangeAndOverflowingValuesWithoutTrapping() throws {
        #expect(try ProjectCacheRulesLoader.editableQuietHours(from: .init()) == 24)
        #expect(try ProjectCacheRulesLoader.editableQuietHours(from: .init(quietHours: 48)) == 48)
        for bad in [0.0, 0.5, 1.5, 169.0, 1e100, Double.infinity, Double.nan] {
            #expect(throws: (any Error).self) {
                _ = try ProjectCacheRulesLoader.editableQuietHours(from: .init(quietHours: bad))
            }
        }
    }

    @Test func editableLinesRoundTripsCommasLosslesslyAndRejectsUnsafeEntries() throws {
        let entries = ["archive,old", "vendor,cache"]
        let text = try ProjectCacheRulesLoader.editableLines(from: entries, field: "skip")
        #expect(ProjectCacheRulesLoader.parseLines(text) == entries)

        for nonRoundTrippable in [["line\nbreak"], [" leading"], ["trailing "], [""]] {
            #expect(throws: (any Error).self) {
                _ = try ProjectCacheRulesLoader.editableLines(from: nonRoundTrippable, field: "skip")
            }
        }
    }

    @Test func saveEnforcesMaximumFileSizeAndPreservesExistingRulesWhenOversized() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let rulesFile = f.base.appending(path: ".config/disksage/rules.json")

        // Compact-eligible near-limit config (pretty-printed > 1 MiB, compact <= 1 MiB) saves compactly and reloads.
        let nearLimit = ProjectCacheRulesLoader.UserConfig(
            skip: Array(repeating: "archive", count: 100_000),
            quietHours: 48
        )
        try ProjectCacheRulesLoader.save(nearLimit, to: rulesFile, home: f.base)
        let savedSize = try FileManager.default.attributesOfItem(atPath: rulesFile.path)[.size] as? NSNumber
        #expect((savedSize?.int64Value ?? .max) <= Int64(ProjectCacheRulesLoader.maximumFileBytes))
        let reloaded = try ProjectCacheRulesLoader.loadConfig(from: rulesFile)
        #expect(reloaded.quietHours == 48)
        #expect(reloaded.skip?.count == 100_000)

        // Truly oversized config (> 1 MiB even when compact) throws and leaves the existing rules file intact.
        let oversized = ProjectCacheRulesLoader.UserConfig(
            skip: Array(repeating: "archive", count: 120_000),
            quietHours: 72
        )
        #expect(throws: (any Error).self) {
            try ProjectCacheRulesLoader.save(oversized, to: rulesFile, home: f.base)
        }
        let stillIntact = try ProjectCacheRulesLoader.loadConfig(from: rulesFile)
        #expect(stillIntact.quietHours == 48)
        #expect(stillIntact.skip?.count == 100_000)
    }

    @Test func invalidExtraRootOnDiskExcludesThatRootWithoutDiscardingProtectiveRules() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let rulesFile = f.base.appending(path: ".config/disksage/rules.json")
        let projects = try f.folder("Projects")
        let work = try f.folder("Work")
        let devApp = f.base.appending(path: "Developer/archive/app")
        try initGitProject(at: devApp, gitignore: "node_modules/\n")
        try f.write("Developer/archive/app/node_modules/pkg/index.js", bytes: 8_192)

        let config = ProjectCacheRulesLoader.UserConfig(
            skip: ["archive"],
            quietHours: 168,
            extraRoots: ["~/Projects", "~/Work"]
        )
        try ProjectCacheRulesLoader.save(config, to: rulesFile, home: f.base)

        // Later, ~/Projects is replaced with a symlink on disk.
        let external = try f.folder("external")
        try FileManager.default.removeItem(at: projects)
        try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: external)

        // Protective rules remain enforced by current() and scanning; only the invalid extra root is excluded.
        let env = ["XDG_CONFIG_HOME": f.base.appending(path: ".config").path]
        let loaded = ProjectCacheRulesLoader.current(home: f.base, env: env)
        #expect(loaded.quietHours == 168)
        #expect(loaded.skip.contains("archive"))
        #expect(ProjectCacheRulesLoader.extraRoots(home: f.base, env: env) == [CleanupPath.fileURL(work)])
        #expect(ProjectCacheInventory.candidates(activity: .idle, now: f.later(hours: 200),
                                                 home: f.base, minimumBytes: 1).isEmpty)
    }

    @Test func symlinkedConfigDirectoryStillLoadsProtectionsWhileRefusingSymlinkWrites() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let dotfiles = try f.folder("dotfiles/disksage")
        try Data(#"{"quiet_hours": 168, "skip": ["archive"]}"#.utf8)
            .write(to: dotfiles.appending(path: "rules.json"))

        let configDir = try f.folder(".config")
        try FileManager.default.createSymbolicLink(
            at: configDir.appending(path: "disksage"),
            withDestinationURL: dotfiles
        )

        // Reading preserves protective rules even when ~/.config/disksage is a dotfiles symlink.
        let env = ["XDG_CONFIG_HOME": configDir.path]
        let loaded = ProjectCacheRulesLoader.current(home: f.base, env: env)
        #expect(loaded.quietHours == 168)
        #expect(loaded.skip.contains("archive"))

        // Writing still refuses traversing symlinked config ancestors.
        let rulesURL = ProjectCacheRulesLoader.configURL(home: f.base, env: env)
        #expect(throws: (any Error).self) {
            try ProjectCacheRulesLoader.save(.init(quietHours: 48), to: rulesURL, home: f.base)
        }
        // Existing rules remain intact.
        #expect(ProjectCacheRulesLoader.current(home: f.base, env: env).quietHours == 168)
    }

    @Test func saveRejectsStaleSnapshotWhenRulesChangedExternally() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let rulesFile = f.base.appending(path: ".config/disksage/rules.json")
        let initial = try ProjectCacheRulesLoader.save(.init(quietHours: 36), to: rulesFile, home: f.base)
        let snapshot = try ProjectCacheRulesLoader.loadConfigSnapshot(from: rulesFile)
        #expect(snapshot.rawData == initial)

        // Simulate an external edit adding a protective refuse_inside rule after Settings loaded.
        try Data(#"{"quiet_hours": 36, "refuse_inside": {"_build": ["custom/*"]}}"#.utf8).write(to: rulesFile)

        // Saving with the stale snapshot fails and preserves the external edit.
        #expect(throws: (any Error).self) {
            try ProjectCacheRulesLoader.save(
                .init(quietHours: 48),
                to: rulesFile,
                home: f.base,
                expectedExistingData: .some(snapshot.rawData)
            )
        }
        let reloaded = try ProjectCacheRulesLoader.loadConfig(from: rulesFile)
        #expect(reloaded.refuseInside?["_build"] == ["custom/*"])
        #expect(reloaded.quietHours == 36)

        // After reloading a fresh snapshot, saving succeeds.
        let fresh = try ProjectCacheRulesLoader.loadConfigSnapshot(from: rulesFile)
        var updated = fresh.config
        updated.quietHours = 48
        try ProjectCacheRulesLoader.save(updated, to: rulesFile, home: f.base,
                                         expectedExistingData: .some(fresh.rawData))
        let finalConfig = try ProjectCacheRulesLoader.loadConfig(from: rulesFile)
        #expect(finalConfig.quietHours == 48)
        #expect(finalConfig.refuseInside?["_build"] == ["custom/*"])
    }

    @Test func loadConfigRejectsFifoWithoutBlocking() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let fifo = f.base.appending(path: ".config/disksage/rules.json")
        try FileManager.default.createDirectory(at: fifo.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) {
            _ = try ProjectCacheRulesLoader.loadConfig(from: fifo)
        }
    }
}
