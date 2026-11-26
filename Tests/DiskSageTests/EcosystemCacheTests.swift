import Darwin
import Foundation
import Testing
@testable import DiskSage

struct EcosystemCacheTests {
    @Test func offersIdleCargoGradleAndMavenCachesAndClearsOnlyContents() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".cargo/registry/cache/index.crates.io/serde-1.0.crate", bytes: 8_192)
        try f.write(".cargo/git/checkouts/dep/lib.rs", bytes: 4_096)
        try f.write(".cargo/credentials.toml", bytes: 256)
        try f.write(".gradle/caches/modules-2/files-2.1/lib.jar", bytes: 8_192)
        try f.write(".gradle/gradle.properties", bytes: 256)
        try f.write(".m2/repository/org/example/lib/1.0/lib-1.0.jar", bytes: 8_192)
        try f.write(".m2/settings.xml", bytes: 256)

        // Too recent: nothing offered before the 1-hour idle window.
        #expect(EcosystemCacheInventory.candidates(activity: .idle, now: f.later(hours: 0.5), home: f.base, minimumBytes: 1).isEmpty)

        let later = f.later(hours: 2)
        let found = EcosystemCacheInventory.candidates(activity: .idle, now: later, home: f.base, minimumBytes: 1)
        let expected = Set([
            CleanupPath.fileURL(f.base.appending(path: ".cargo/registry")),
            CleanupPath.fileURL(f.base.appending(path: ".gradle/caches")),
            CleanupPath.fileURL(f.base.appending(path: ".m2/repository")),
        ])
        #expect(Set(found.map(\.url)) == expected)
        #expect(found.allSatisfy { $0.deletionMode == .contents && $0.risk == .low && $0.category == .cache })

        for candidate in found {
            try SafetyPolicy(home: f.base, now: later).validate(candidate)
            try EcosystemCacheInventory.verifyBeforeDeletion(candidate, activity: .idle, now: later, home: f.base)
            try SecureFileDeleter.delete(candidate, entryRemoved: {})
            // The cache folder stays in place; its contents are gone.
            #expect(f.exists(candidate.url))
            #expect(try FileManager.default.contentsOfDirectory(atPath: candidate.url.path).isEmpty)
        }
        // Sibling Git checkouts and credentials remain untouched.
        #expect(f.exists(f.base.appending(path: ".cargo/git/checkouts/dep/lib.rs")))
        #expect(f.exists(f.base.appending(path: ".cargo/credentials.toml")))
        #expect(f.exists(f.base.appending(path: ".gradle/gradle.properties")))
        #expect(f.exists(f.base.appending(path: ".m2/settings.xml")))
    }

    @Test func mavenRepositoryWithLocalMetadataIsRefusedAtScanAndBeforeDeletion() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".m2/repository/org/example/app/1.0/app-1.0.jar", bytes: 8_192)
        let later = f.later(hours: 2)
        let offered = try #require(EcosystemCacheInventory.candidates(activity: .idle, now: later, home: f.base, minimumBytes: 1).first)

        // Adding maven-metadata-local.xml blocks both fresh scans and pre-deletion revalidation.
        try f.write(".m2/repository/org/example/app/maven-metadata-local.xml", bytes: 128)
        #expect(EcosystemCacheInventory.candidates(activity: .idle, now: later, home: f.base, minimumBytes: 1).isEmpty)
        #expect(throws: (any Error).self) {
            try EcosystemCacheInventory.verifyBeforeDeletion(offered, activity: .idle, now: later, home: f.base)
        }
    }

    @Test func refusesGitRepositoriesInsideCachesBusyCommandsAndItemDeletionMode() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".cargo/registry/src/pkg/.git/HEAD", bytes: 64)
        try f.write(".gradle/caches/modules-2/a.jar", bytes: 8_192)
        let later = f.later(hours: 2)

        // Cargo registry containing a Git repo is refused; Gradle remains offered.
        let found = EcosystemCacheInventory.candidates(activity: .idle, now: later, home: f.base, minimumBytes: 1)
        #expect(found.map(\.name) == ["Gradle global cache"])

        // Running gradle command blocks Gradle cache at scan and pre-deletion.
        let gradleBusy = CleanupActivity(paths: [], commands: ["gradle"])
        #expect(EcosystemCacheInventory.candidates(activity: gradleBusy, now: later, home: f.base, minimumBytes: 1).isEmpty)
        let gradle = try #require(found.first)
        #expect(throws: (any Error).self) {
            try EcosystemCacheInventory.verifyBeforeDeletion(gradle, activity: gradleBusy, now: later, home: f.base)
        }

        // Whole-directory (.item) deletion is refused by SafetyPolicy.
        let asItem = CleanupCandidate(url: gradle.url, name: gradle.name, category: .cache, size: gradle.size,
                                      risk: .low, reason: gradle.reason, identity: gradle.identity, deletionMode: .item)
        #expect(throws: SafetyPolicyError.self) { try SafetyPolicy(home: f.base, now: later).validate(asItem) }
    }

    @Test func respectsKeepRulesAndSymlinks() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".gradle/caches/a.jar", bytes: 8_192)
        let gradle = CleanupPath.fileURL(f.base.appending(path: ".gradle/caches"))
        let later = f.later(hours: 2)
        let offered = try #require(EcosystemCacheInventory.candidates(activity: .idle, now: later, home: f.base, minimumBytes: 1).first)
        #expect(throws: SafetyPolicyError.self) {
            try SafetyPolicy(home: f.base, now: later, keep: KeepRules(paths: [gradle.path])).validate(offered)
        }

        // A symlinked cache directory is never offered.
        let target = try f.folder("elsewhere")
        try f.write("elsewhere/a.crate", bytes: 8_192)
        try FileManager.default.createDirectory(at: f.base.appending(path: ".cargo"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.base.appending(path: ".cargo/registry"), withDestinationURL: target)
        let afterLink = EcosystemCacheInventory.candidates(activity: .idle, now: later, home: f.base, minimumBytes: 1)
        #expect(afterLink.map(\.url) == [gradle])
    }

    @Test func offersCocoaPodsAtLowRiskAndPlaywrightPuppeteerAsReviewItems() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Library/Caches/CocoaPods/Pods/Release/Alamofire/file.a", bytes: 8_192)
        try f.write("Library/Caches/ms-playwright/chromium-1148/chrome", bytes: 16_384)
        try f.write(".cache/puppeteer/chrome/mac_arm-131/chrome", bytes: 16_384)

        let later = f.later(hours: 2)
        let found = EcosystemCacheInventory.candidates(activity: .idle, now: later, home: f.base, minimumBytes: 1)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        let pods = try #require(byName["CocoaPods cache"])
        let playwright = try #require(byName["Playwright browsers"])
        let puppeteer = try #require(byName["Puppeteer browsers"])

        #expect(pods.risk == .low)
        #expect(playwright.risk == .medium)
        #expect(puppeteer.risk == .medium)
        #expect(found.allSatisfy { $0.deletionMode == .contents && $0.category == .cache })

        // Active browser executable inside ms-playwright blocks Playwright at scan and pre-deletion.
        let browserOpen = CleanupActivity(paths: [CleanupPath.fileURL(f.base.appending(path: "Library/Caches/ms-playwright/chromium-1148/chrome")).path])
        let whileRunning = EcosystemCacheInventory.candidates(activity: browserOpen, now: later, home: f.base, minimumBytes: 1)
        #expect(!whileRunning.contains { $0.name == "Playwright browsers" })
        #expect(throws: (any Error).self) {
            try EcosystemCacheInventory.verifyBeforeDeletion(playwright, activity: browserOpen, now: later, home: f.base)
        }

        for candidate in [pods, playwright, puppeteer] {
            try SafetyPolicy(home: f.base, now: later).validate(candidate)
            try EcosystemCacheInventory.verifyBeforeDeletion(candidate, activity: .idle, now: later, home: f.base)
            try SecureFileDeleter.delete(candidate, entryRemoved: {})
            #expect(f.exists(candidate.url))
            #expect(try FileManager.default.contentsOfDirectory(atPath: candidate.url.path).isEmpty)
        }
    }

    @Test func offersSwiftPMManifestsMirrorsUpdaterCachesAndCodexPlusHuggingFace() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let git = WorktreeGitProcess()

        // Valid SwiftPM manifest cache and verified bare mirror under repositories/.
        try f.write("Library/Caches/org.swift.swiftpm/manifests/manifest.db", bytes: 4_096)
        let upstream = f.base.appending(path: "upstream/Pkg")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        _ = try git.run(upstream.path, ["init", "-b", "main"])
        _ = try git.run(upstream.path, ["config", "user.name", "Test"])
        _ = try git.run(upstream.path, ["config", "user.email", "test@example.com"])
        try Data("// swift-tools-version: 6.0\n".utf8).write(to: upstream.appending(path: "Package.swift"))
        _ = try git.run(upstream.path, ["add", "Package.swift"])
        _ = try git.run(upstream.path, ["commit", "-m", "Initial"])
        let mirrorsRoot = f.base.appending(path: "Library/Caches/org.swift.swiftpm/repositories")
        try FileManager.default.createDirectory(at: mirrorsRoot, withIntermediateDirectories: true)
        _ = try git.run(mirrorsRoot.path, ["clone", "--mirror", upstream.path, "Pkg-deadbeef"])

        // Codex runtimes + HuggingFace caches (24h idle minimum, medium risk) and Squirrel updaters.
        try f.write(".cache/codex-runtimes/codex-primary-runtime/runtime.json", bytes: 4_096)
        try f.write(".cache/huggingface/token", bytes: 64)
        try f.write(".cache/huggingface/stored_tokens", bytes: 64)
        try f.write(".cache/huggingface/hub/model.safetensors", bytes: 4_096)
        try f.write(".cache/huggingface/datasets/ds.arrow", bytes: 4_096)
        try f.write(".cache/huggingface/assets/a.bin", bytes: 4_096)
        try f.write(".cache/huggingface/xet/chunk.bin", bytes: 4_096)
        try f.write("Library/Caches/com.microsoft.VSCode.ShipIt/update.zip", bytes: 4_096)
        try f.write("Library/Caches/t3code-updater/update.zip", bytes: 11 * 1_048_576)

        // At 2h: SwiftPM manifests + mirrors are offered (.low); 24h caches stay hidden.
        let at2h = f.later(hours: 2)
        let earlyNames = Set(EcosystemCacheInventory.candidates(activity: .idle, now: at2h, home: f.base, minimumBytes: 1).map(\.name))
        #expect(earlyNames == Set(["SwiftPM manifest cache", "SwiftPM repository mirrors"]))

        // At 30h: Codex, HuggingFace subdirectories, and both updaters appear at .medium risk.
        let at30h = f.later(hours: 30)
        let midCandidates = EcosystemCacheInventory.candidates(activity: .idle, now: at30h, home: f.base, minimumBytes: 1)
        let mid = Dictionary(uniqueKeysWithValues: midCandidates.map { ($0.name, $0) })
        #expect(mid["Codex runtimes cache"]?.risk == .medium)
        #expect(mid["Hugging Face Hub cache"]?.risk == .medium)
        #expect(mid["Hugging Face datasets cache"]?.risk == .medium)
        #expect(mid["Hugging Face assets cache"]?.risk == .medium)
        #expect(mid["Hugging Face Xet cache"]?.risk == .medium)
        #expect(!midCandidates.contains { $0.url == CleanupPath.fileURL(f.base.appending(path: ".cache/huggingface")) })
        #expect(mid["com.microsoft.VSCode.ShipIt updater cache"]?.risk == .medium)
        #expect(mid["t3code-updater updater cache"]?.risk == .medium)
        // Default minimumBytes (100 MiB) still admits updater caches above 10 MiB.
        let defaultSized = EcosystemCacheInventory.candidates(activity: .idle, now: at30h, home: f.base)
        #expect(defaultSized.map(\.name) == ["t3code-updater updater cache"])
        // Running ShipIt blocks updater caches cleanly.
        let shipItBusy = EcosystemCacheInventory.candidates(activity: CleanupActivity(paths: [], commands: ["ShipIt"]), now: at30h, home: f.base, minimumBytes: 1)
        #expect(!shipItBusy.contains { $0.name.contains("updater cache") })

        // At 80h (>= 72h): updater caches escalate to .low, while Codex & HuggingFace remain .medium.
        let at80h = f.later(hours: 80)
        let late = Dictionary(uniqueKeysWithValues: EcosystemCacheInventory.candidates(activity: .idle, now: at80h, home: f.base, minimumBytes: 1).map { ($0.name, $0) })
        #expect(late["com.microsoft.VSCode.ShipIt updater cache"]?.risk == .low)
        #expect(late["Codex runtimes cache"]?.risk == .medium)
        #expect(late["Hugging Face Hub cache"]?.risk == .medium)
        #expect(late["Hugging Face datasets cache"]?.risk == .medium)
        #expect(late["Hugging Face assets cache"]?.risk == .medium)
        #expect(late["Hugging Face Xet cache"]?.risk == .medium)

        // Verify diagnostics & cleanups for mirrors, manifests, updaters, and HuggingFace subdirectories.
        let mirrorsURL = CleanupPath.fileURL(mirrorsRoot)
        let mirrorDiag = PathDiagnostics.explain(mirrorsURL.path, activity: .idle, now: at2h, home: f.base, git: git, minimumGlobalBytes: 1)
        #expect(mirrorDiag.verdict == .eligible && mirrorDiag.risk == "low")
        for key in ["SwiftPM manifest cache", "SwiftPM repository mirrors", "com.microsoft.VSCode.ShipIt updater cache",
                    "Hugging Face Hub cache", "Hugging Face datasets cache", "Hugging Face assets cache", "Hugging Face Xet cache"] {
            let candidate = try #require(late[key])
            try SafetyPolicy(home: f.base, now: at80h).validate(candidate)
            try EcosystemCacheInventory.verifyBeforeDeletion(candidate, activity: .idle, now: at80h, home: f.base)
            try SecureFileDeleter.delete(candidate, entryRemoved: {})
            #expect(f.exists(candidate.url))
            #expect(try FileManager.default.contentsOfDirectory(atPath: candidate.url.path).isEmpty)
        }
        // Persistent HF login credentials at ~/.cache/huggingface stay untouched.
        #expect(f.exists(f.base.appending(path: ".cache/huggingface/token")))
        #expect(f.exists(f.base.appending(path: ".cache/huggingface/stored_tokens")))

        // Tamper with SwiftPM repositories by adding an unexpected file / non-mirror repo -> refused everywhere.
        try f.write("Library/Caches/org.swift.swiftpm/repositories/rogue.txt", bytes: 64)
        #expect(!EcosystemCacheInventory.candidates(activity: .idle, now: f.later(hours: 100), home: f.base, minimumBytes: 1).contains { $0.name == "SwiftPM repository mirrors" })
        let tamperedDiag = PathDiagnostics.explain(mirrorsURL.path, activity: .idle, now: f.later(hours: 100), home: f.base, git: git, minimumGlobalBytes: 1)
        #expect(tamperedDiag.verdict == .skipped)
    }
}
