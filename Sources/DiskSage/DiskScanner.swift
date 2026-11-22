import Foundation
import Darwin

struct DiskScanner: Sendable {
    struct Location: Sendable {
        let url: URL
        let name: String
        let category: CandidateCategory
        let risk: RiskLevel
        let reason: String
        let deletionMode: DeletionMode
    }

    private struct WholeFolderBranch: Sendable {
        let index: Int
        var candidates: [CleanupCandidate] = []
        var generatedRoots: [URL] = []
        var warnings: [String] = []
    }

    private struct SeedResult: Sendable {
        let index: Int
        let candidate: CleanupCandidate?
        let warning: String?
    }

    private let locations: [Location]?
    private let activity: @Sendable () throws -> CleanupActivity
    private let inventoryLimit: Int
    private let maxConcurrency: Int
    init(locations: [Location]? = nil, activity: @escaping @Sendable () throws -> CleanupActivity = { try CleanupActivity.capture() },
         inventoryLimit: Int = GeneratedFileInventory.defaultMaximumEntries, maxConcurrency: Int = 4) {
        self.locations = locations
        self.activity = activity
        self.inventoryLimit = inventoryLimit
        self.maxConcurrency = min(4, max(1, maxConcurrency))
    }

    func scan() async throws -> [CleanupCandidate] { try await report().candidates }

    /// Throws when the activity check fails. An empty result means that the scan ran and found nothing.
    func report() async throws -> ScanReport {
        let task = Task.detached(priority: .utility) { [locations, activity, inventoryLimit, maxConcurrency] in
            try await Self.scanConcurrently(locations: locations, activity: activity,
                                            inventoryLimit: inventoryLimit, maxConcurrency: maxConcurrency)
        }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { task.cancel() }
            do {
                let results = try await task.value
                return Task.isCancelled ? ScanReport(candidates: []) : results
            } catch {
                // A cancelled scan stops its activity check; that is not a failure.
                if Task.isCancelled { return ScanReport(candidates: []) }
                throw error
            }
        } onCancel: { task.cancel() }
    }

    private static func scanConcurrently(locations: [Location]?, activity: @Sendable () throws -> CleanupActivity,
                                         inventoryLimit: Int, maxConcurrency: Int) async throws -> ScanReport {
        guard !Task.isCancelled else { return ScanReport(candidates: []) }
        // A failed/incomplete activity check never turns into permission to delete. It is an error, not an empty disk.
        let currentActivity: CleanupActivity
        do { currentActivity = try activity() } catch {
            throw FeatureFailure(message: "The scan could not check which folders are in use: \(error.localizedDescription)")
        }
        let home = CleanupPath.fileURL(FileManager.default.homeDirectoryForCurrentUser)
        var seeds = locations ?? defaultLocations(home: home)
        var wholeFolders: [CleanupCandidate] = [], warnings: [String] = []
        if locations == nil {
            let branches = await scanWholeFolderInventories(activity: currentActivity, home: home)
            guard !Task.isCancelled else { return ScanReport(candidates: []) }
            for branch in branches {
                wholeFolders += branch.candidates
                warnings += branch.warnings
                seeds += branch.generatedRoots.map {
                    Location(url: $0, name: $0.path.replacingOccurrences(of: home.path + "/", with: ""),
                        category: .build, risk: .low, reason: "Generated files only", deletionMode: .generatedFiles)
                }
            }
        }
        let uniqueSeeds = deduplicatedSeeds(seeds)
        let seedResults = await inspectSeeds(uniqueSeeds, activity: currentActivity, home: home,
                                             inventoryLimit: inventoryLimit, maxConcurrency: maxConcurrency)
        guard !Task.isCancelled else { return ScanReport(candidates: []) }
        var candidates: [CleanupCandidate] = []
        for result in seedResults {
            if let candidate = result.candidate { candidates.append(candidate) }
            if let warning = result.warning { warnings.append(warning) }
        }
        let offered = validated(candidates + wholeFolders)
            .sorted { lhs, rhs in
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                if lhs.url.path != rhs.url.path { return lhs.url.path < rhs.url.path }
                return lhs.name < rhs.name
            }
            .prefix(100)
            .map { $0 }
        return ScanReport(candidates: offered, warnings: Task.isCancelled ? [] : warnings)
    }

    private static func scanWholeFolderInventories(activity: CleanupActivity, home: URL) async -> [WholeFolderBranch] {
        await withTaskGroup(of: WholeFolderBranch.self) { group in
            group.addTask {
                var discoveryWarnings: [String] = []
                let discovered = GeneratedCleanupScope.discoveryRoots(home: home).flatMap { root -> [URL] in
                    guard !Task.isCancelled else { return [] }
                    let result = GeneratedBuildDiscovery().discover(under: root)
                    if result.limitReached { discoveryWarnings.append(discoveryWarning(root, home: home)) }
                    return result.directories
                }
                guard !Task.isCancelled else { return WholeFolderBranch(index: 0) }
                let temporary = TemporaryBuildInspector.scan(discovered: discovered, activity: activity, home: home)
                return WholeFolderBranch(index: 0, candidates: temporary.candidates,
                                         generatedRoots: temporary.generatedRoots, warnings: discoveryWarnings)
            }
            group.addTask {
                WholeFolderBranch(index: 1, candidates: ProjectCacheInventory.candidates(activity: activity, home: home))
            }
            group.addTask {
                WholeFolderBranch(index: 2, candidates:
                    SimulatorInventory.candidates(activity: activity, home: home) +
                    SimulatorRuntimeInventory.candidates(activity: activity, home: home))
            }
            group.addTask {
                WholeFolderBranch(index: 3, candidates: ToolCacheInventory.candidates(activity: activity, home: home))
            }
            group.addTask {
                WholeFolderBranch(index: 4, candidates: EcosystemCacheInventory.candidates(activity: activity, home: home))
            }
            var branches: [WholeFolderBranch] = []
            for await branch in group { branches.append(branch) }
            return branches.sorted { $0.index < $1.index }
        }
    }

    private static func deduplicatedSeeds(_ seeds: [Location]) -> [(Location, URL)] {
        var seen = Set<String>()
        return seeds.compactMap { seed in
            let url = CleanupPath.fileURL(seed.url)
            guard seen.insert(url.path).inserted else { return nil }
            return (seed, url)
        }
    }

    private static func inspectSeeds(_ seeds: [(Location, URL)], activity: CleanupActivity, home: URL,
                                     inventoryLimit: Int, maxConcurrency: Int) async -> [SeedResult] {
        await withTaskGroup(of: SeedResult.self) { group in
            var nextIndex = 0
            var results: [SeedResult] = []
            results.reserveCapacity(seeds.count)
            let limit = min(maxConcurrency, seeds.count)
            while nextIndex < limit {
                let index = nextIndex
                let (seed, url) = seeds[index]
                nextIndex += 1
                group.addTask { inspectSeed(seed, url: url, index: index, activity: activity, home: home, inventoryLimit: inventoryLimit) }
            }
            while let result = await group.next() {
                results.append(result)
                if !Task.isCancelled, nextIndex < seeds.count {
                    let index = nextIndex
                    let (seed, url) = seeds[index]
                    nextIndex += 1
                    group.addTask { inspectSeed(seed, url: url, index: index, activity: activity, home: home, inventoryLimit: inventoryLimit) }
                }
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private static func inspectSeed(_ seed: Location, url: URL, index: Int, activity: CleanupActivity,
                                    home: URL, inventoryLimit: Int) -> SeedResult {
        guard !Task.isCancelled else { return SeedResult(index: index, candidate: nil, warning: nil) }
        if seed.deletionMode == .generatedFiles {
            guard let rule = GeneratedCleanupScope.rule(for: url, home: home) else {
                return SeedResult(index: index, candidate: nil, warning: nil)
            }
            do {
                // This scan also offers whole folders, so idle DerivedData projects go to that rule.
                let candidate = try GeneratedFileDeleter.inspect(url, name: seed.name, category: seed.category, rule: rule,
                    activity: activity, handsOffWholeFolders: true, maximumEntries: inventoryLimit)
                return SeedResult(index: index, candidate: candidate, warning: nil)
            } catch let limit as InventoryLimitExceeded {
                // Nothing is offered from a partial list, but the user must know why the folder is missing.
                return SeedResult(index: index, candidate: nil, warning: "\(seed.name) was skipped. \(limit.localizedDescription)")
            } catch {
                // A missing folder or a folder in use is a normal skip.
                return SeedResult(index: index, candidate: nil, warning: nil)
            }
        }
        guard !activity.contains(url) else { return SeedResult(index: index, candidate: nil, warning: nil) }
        let candidate = inspect(url, name: seed.name, category: seed.category, risk: seed.risk,
                                reason: seed.reason, deletionMode: seed.deletionMode)
        return SeedResult(index: index, candidate: candidate, warning: nil)
    }

    private static func discoveryWarning(_ root: URL, home: URL) -> String {
        let place = root.path.hasPrefix(home.path + "/") ? "~/" + root.path.dropFirst(home.path.count + 1) : root.path
        return "The search for build folders in \(place) stopped at its safety limit. Some build folders were not checked."
    }

    private static func defaultLocations(home: URL) -> [Location] {
        GeneratedCleanupScope.fixedLocations(home: home).map { url, name, rule in
            Location(url: url, name: name, category: rule == .buildArtifacts || rule == .goBuild ? .build : .cache,
                risk: .low, reason: "Verified generated files only", deletionMode: .generatedFiles)
        }
    }

    static func validated(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        guard !Task.isCancelled else { return [] }
        return candidates.filter { (try? SafetyPolicy().validate($0)) != nil }
    }

    /// Legacy explicit whole-folder operations retain their separate authorization path.
    static func inspect(_ url: URL, name: String, category: CandidateCategory, risk: RiskLevel,
                        reason: String, deletionMode: DeletionMode = .item) -> CleanupCandidate? {
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: url.path),
              !isSymbolicLink(url), !containsRunningExecutable(url), let identity = fileIdentity(of: url) else { return nil }
        let proposed = CleanupCandidate(url: url, name: name, category: category, size: 0,
            risk: risk, reason: reason, identity: identity, deletionMode: deletionMode)
        guard (try? SafetyPolicy().validate(proposed)) != nil,
              let size = allocatedSize(of: url), size > 0, !Task.isCancelled else { return nil }
        return CleanupCandidate(id: proposed.id, url: url, name: name, category: category, size: size,
            risk: risk, reason: reason, identity: identity, deletionMode: deletionMode)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func containsRunningExecutable(_ url: URL) -> Bool {
        guard let executable = Bundle.main.executableURL.map(CleanupPath.fileURL) else { return false }
        return executable.path.hasPrefix(CleanupPath.fileURL(url).path + "/")
    }

    private static func fileIdentity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func allocatedSize(of root: URL) -> Int64? {
        guard !Task.isCancelled else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var tally = ReclaimableSize.Tally()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }) else {
            tally.add(path: root.path)
            return tally.total
        }
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            tally.add(path: fileURL.path)
        }
        return tally.total
    }
}
