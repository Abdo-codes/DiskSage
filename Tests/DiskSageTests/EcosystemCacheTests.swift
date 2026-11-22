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
}
