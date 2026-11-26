import Darwin
import Foundation

/// Global package-manager caches that have no safe built-in cleanup command.
/// DiskSage clears only the directory's contents (keeping the folder itself),
/// leaves sibling config, credentials, and Git checkouts untouched, and refuses
/// directories holding Git repositories or locally installed artifacts.
enum EcosystemCacheInventory {
    struct Rule: Sendable, Equatable {
        let name: String
        let folder: URL
        let risk: RiskLevel
        /// Any entry with one of these names anywhere below `folder` blocks cleanup.
        let refuseNames: Set<String>
        /// Running process names that make cleanup unsafe even without an open file in `folder`.
        let blockedCommands: Set<String>
        let reason: String
        var minimumIdle: TimeInterval = EcosystemCacheInventory.minimumIdle
        var minimumBytes: Int64? = nil
        var lowRiskAfterIdle: TimeInterval? = nil
        var allowSwiftPMMirrors: Bool = false

        func effectiveRisk(idle: TimeInterval) -> RiskLevel {
            if let lowRiskAfterIdle, idle >= lowRiskAfterIdle { return .low }
            return risk
        }
    }

    static let minimumBytes: Int64 = ToolCacheInventory.minimumBytes
    static let minimumIdle: TimeInterval = GeneratedCleanupPolicy.minimumAge

    private static func staticRules(home: URL) -> [Rule] {
        let home = CleanupPath.fileURL(home)
        return [
            Rule(name: "Cargo registry cache",
                 folder: home.appending(path: ".cargo/registry", directoryHint: .isDirectory),
                 risk: .low,
                 refuseNames: [],
                 blockedCommands: ["cargo", "rustc", "rust-analyzer"],
                 reason: "Downloaded crate archives and extracted registry sources in `~/.cargo/registry`. Cargo downloads them again; `~/.cargo/git`, `bin`, and credentials stay."),
            Rule(name: "Gradle global cache",
                 folder: home.appending(path: ".gradle/caches", directoryHint: .isDirectory),
                 risk: .low,
                 refuseNames: [],
                 blockedCommands: ["gradle", "gradlew"],
                 reason: "Downloaded dependencies, transforms, and build caches in `~/.gradle/caches`. Gradle rebuilds them; `gradle.properties`, `wrapper`, `jdks`, and `init.d` stay."),
            Rule(name: "Maven local repository",
                 folder: home.appending(path: ".m2/repository", directoryHint: .isDirectory),
                 risk: .low,
                 // `mvn install` writes maven-metadata-local.xml for local-only artifacts that no remote holds.
                 refuseNames: ["maven-metadata-local.xml"],
                 blockedCommands: ["mvn", "mvnw"],
                 reason: "Downloaded artifacts in `~/.m2/repository` with no local-only `maven-metadata-local.xml` files. Maven downloads them again; `~/.m2/settings.xml` stays."),
            Rule(name: "CocoaPods cache",
                 folder: home.appending(path: "Library/Caches/CocoaPods", directoryHint: .isDirectory),
                 risk: .low,
                 refuseNames: [],
                 blockedCommands: ["pod"],
                 reason: "Downloaded pod archives and specs in `~/Library/Caches/CocoaPods`. CocoaPods downloads them again on `pod install`."),
            Rule(name: "SwiftPM manifest cache",
                 folder: home.appending(path: "Library/Caches/org.swift.swiftpm/manifests", directoryHint: .isDirectory),
                 risk: .low,
                 refuseNames: [],
                 blockedCommands: ["swift", "swift-build", "swift-package", "xcodebuild", "sourcekit-lsp", "Xcode"],
                 reason: "Cached Swift Package Manager manifest metadata in `~/Library/Caches/org.swift.swiftpm/manifests`. SwiftPM regenerates them cleanly."),
            Rule(name: "SwiftPM repository mirrors",
                 folder: home.appending(path: "Library/Caches/org.swift.swiftpm/repositories", directoryHint: .isDirectory),
                 risk: .low,
                 refuseNames: [],
                 blockedCommands: ["swift", "swift-build", "swift-package", "xcodebuild", "sourcekit-lsp", "Xcode"],
                 reason: "Unmodified bare Git mirrors cloned by SwiftPM in `~/Library/Caches/org.swift.swiftpm/repositories`. SwiftPM clones them again during package resolution.",
                 allowSwiftPMMirrors: true),
            Rule(name: "Codex runtimes cache",
                 folder: home.appending(path: ".cache/codex-runtimes", directoryHint: .isDirectory),
                 risk: .medium,
                 refuseNames: [],
                 blockedCommands: ["codex"],
                 reason: "Cached Codex CLI runtime bundles in `~/.cache/codex-runtimes`. Codex downloads them again when needed.",
                 minimumIdle: 24 * 3_600),
            Rule(name: "Hugging Face Hub cache",
                 folder: home.appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory),
                 risk: .medium,
                 refuseNames: [],
                 blockedCommands: ["hf", "huggingface-cli"],
                 reason: "Downloaded models and repositories in `~/.cache/huggingface/hub`. Sibling credentials (`token`, `stored_tokens`) stay; re-downloading large weights takes bandwidth and time.",
                 minimumIdle: 24 * 3_600),
            Rule(name: "Hugging Face datasets cache",
                 folder: home.appending(path: ".cache/huggingface/datasets", directoryHint: .isDirectory),
                 risk: .medium,
                 refuseNames: [],
                 blockedCommands: ["hf", "huggingface-cli"],
                 reason: "Downloaded datasets in `~/.cache/huggingface/datasets`. Sibling credentials (`token`, `stored_tokens`) stay; re-downloading datasets takes bandwidth and time.",
                 minimumIdle: 24 * 3_600),
            Rule(name: "Hugging Face assets cache",
                 folder: home.appending(path: ".cache/huggingface/assets", directoryHint: .isDirectory),
                 risk: .medium,
                 refuseNames: [],
                 blockedCommands: ["hf", "huggingface-cli"],
                 reason: "Cached library assets in `~/.cache/huggingface/assets`. Sibling credentials (`token`, `stored_tokens`) stay.",
                 minimumIdle: 24 * 3_600),
            Rule(name: "Hugging Face Xet cache",
                 folder: home.appending(path: ".cache/huggingface/xet", directoryHint: .isDirectory),
                 risk: .medium,
                 refuseNames: [],
                 blockedCommands: ["hf", "huggingface-cli"],
                 reason: "Downloaded Xet chunks in `~/.cache/huggingface/xet`. Sibling credentials (`token`, `stored_tokens`) stay; re-downloading chunks takes bandwidth and time.",
                 minimumIdle: 24 * 3_600),
            Rule(name: "Playwright browsers",
                 folder: home.appending(path: "Library/Caches/ms-playwright", directoryHint: .isDirectory),
                 risk: .medium,
                 refuseNames: [],
                 blockedCommands: ["playwright"],
                 reason: "Downloaded browser binaries in `~/Library/Caches/ms-playwright`. Re-run `playwright install` to restore them."),
            Rule(name: "Puppeteer browsers",
                 folder: home.appending(path: ".cache/puppeteer", directoryHint: .isDirectory),
                 risk: .medium,
                 refuseNames: [],
                 blockedCommands: ["puppeteer"],
                 reason: "Downloaded browser binaries in `~/.cache/puppeteer`. Puppeteer downloads them again when reinstalled."),
        ]
    }

    static func updaterRule(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Rule? {
        let canonical = CleanupPath.fileURL(url)
        let caches = CleanupPath.fileURL(home).appending(path: "Library/Caches", directoryHint: .isDirectory)
        guard canonical.deletingLastPathComponent() == caches else { return nil }
        let name = canonical.lastPathComponent
        let isUpdater = (name.hasSuffix(".ShipIt") && name.count > 7) || (name.hasSuffix("-updater") && name.count > 8)
        guard isUpdater else { return nil }
        return Rule(
            name: "\(name) updater cache",
            folder: canonical,
            risk: .medium,
            refuseNames: [],
            blockedCommands: ["ShipIt"],
            reason: "Downloaded app update installers in `~/Library/Caches/\(name)`. The app downloads updates again when needed.",
            minimumIdle: 24 * 3_600,
            minimumBytes: 10 * 1_048_576,
            lowRiskAfterIdle: 72 * 3_600
        )
    }

    static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Rule] {
        let home = CleanupPath.fileURL(home)
        var rules = staticRules(home: home)
        let caches = home.appending(path: "Library/Caches", directoryHint: .isDirectory)
        if TemporaryBuildOutput.isRealDirectory(caches),
           let names = try? FileManager.default.contentsOfDirectory(atPath: caches.path) {
            for name in names.sorted() {
                let child = caches.appending(path: name, directoryHint: .isDirectory)
                if TemporaryBuildOutput.isRealDirectory(child), let rule = updaterRule(for: child, home: home) {
                    rules.append(rule)
                }
            }
        }
        return rules
    }

    static func matching(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Rule? {
        let canonical = CleanupPath.fileURL(url)
        let path = canonical.path
        return staticRules(home: home).first { $0.folder.path == path } ?? updaterRule(for: canonical, home: home)
    }

    static func candidates(activity: CleanupActivity, now: Date = Date(),
                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           minimumBytes: Int64 = minimumBytes) -> [CleanupCandidate] {
        all(home: home).compactMap { rule in
            guard !Task.isCancelled else { return nil }
            return inspect(rule, activity: activity, now: now, home: home, minimumBytes: minimumBytes)
        }
    }

    static func inspect(_ rule: Rule, activity: CleanupActivity, now: Date = Date(),
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        minimumBytes: Int64 = minimumBytes) -> CleanupCandidate? {
        let url = CleanupPath.fileURL(rule.folder)
        let threshold = min(minimumBytes, rule.minimumBytes ?? minimumBytes)
        guard TemporaryBuildOutput.isRealDirectory(url),
              !isBusy(rule, activity: activity),
              let survey = try? FolderSurvey.read(url, gitAllowedUnder: rule.allowSwiftPMMirrors ? nil : []) else { return nil }
        let idle = survey.idle(at: now)
        guard survey.bytes >= threshold, idle >= rule.minimumIdle,
              (try? verifyNoRefusedNames(in: url, refused: rule.refuseNames)) != nil else { return nil }
        if rule.allowSwiftPMMirrors {
            guard (try? SwiftPMCheckoutGuard.verifyMirrorsDirectory(url)) != nil else { return nil }
        }
        guard let identity = identity(of: url) else { return nil }
        let candidate = CleanupCandidate(url: url, name: rule.name, category: .cache, size: survey.bytes,
                                         risk: rule.effectiveRisk(idle: idle), reason: rule.reason,
                                         identity: identity, deletionMode: .contents)
        guard (try? SafetyPolicy(home: home, now: now).validate(candidate)) != nil else { return nil }
        return candidate
    }

    /// Runs again right before deleting contents: the folder must still be an allowed ecosystem cache,
    /// idle, free of Git data (or verified SwiftPM mirrors), and free of any refused local-artifact markers.
    static func verifyBeforeDeletion(_ candidate: CleanupCandidate, activity: CleanupActivity,
                                     now: Date = Date(),
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = CleanupPath.fileURL(candidate.url)
        guard let rule = matching(url, home: home) else {
            throw SafetyPolicyError.refused("The folder is not a known ecosystem cache.")
        }
        guard candidate.deletionMode == .contents else {
            throw SafetyPolicyError.refused("Ecosystem caches remove only their contents.")
        }
        guard !isBusy(rule, activity: activity) else {
            throw FeatureFailure(message: "\(rule.name) is in use. Close its builds and scan again.")
        }
        let survey = try FolderSurvey.read(url, gitAllowedUnder: rule.allowSwiftPMMirrors ? nil : [])
        let idle = survey.idle(at: now)
        guard idle >= rule.minimumIdle, rule.effectiveRisk(idle: idle) <= candidate.risk else {
            throw FeatureFailure(message: "\(rule.name) changed recently. Scan again after it is idle.")
        }
        try verifyNoRefusedNames(in: url, refused: rule.refuseNames)
        if rule.allowSwiftPMMirrors {
            try SwiftPMCheckoutGuard.verifyMirrorsDirectory(url)
        }
    }

    private static func isBusy(_ rule: Rule, activity: CleanupActivity) -> Bool {
        activity.contains(rule.folder) || !activity.commands.isDisjoint(with: rule.blockedCommands)
    }

    /// Walks without following symlinks and throws if any entry matches `refused` or cannot be read.
    static func verifyNoRefusedNames(in root: URL, refused: Set<String>, maximumEntries: Int = 1_000_000) throws {
        guard !refused.isEmpty else { return }
        var failed = false, count = 0
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in failed = true; return false }) else {
            throw FeatureFailure(message: "Could not inspect \(root.lastPathComponent) for protected local files.")
        }
        for case let url as URL in walker {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumEntries else {
                throw FeatureFailure(message: "\(root.lastPathComponent) exceeded its inspection limit.")
            }
            if refused.contains(url.lastPathComponent) {
                throw SafetyPolicyError.refused("\(root.lastPathComponent) contains \(url.lastPathComponent), which marks locally installed artifacts.")
            }
        }
        guard !failed else {
            throw FeatureFailure(message: "Some folders inside \(root.lastPathComponent) could not be read.")
        }
    }

    private static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
