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

    private let locations: [Location]?
    private let activity: @Sendable () throws -> CleanupActivity
    private let inventoryLimit: Int
    init(locations: [Location]? = nil, activity: @escaping @Sendable () throws -> CleanupActivity = { try CleanupActivity.capture() },
         inventoryLimit: Int = GeneratedFileInventory.defaultMaximumEntries) {
        self.locations = locations; self.activity = activity; self.inventoryLimit = inventoryLimit
    }

    func scan() async throws -> [CleanupCandidate] { try await report().candidates }

    /// Throws when the activity check fails. An empty result means that the scan ran and found nothing.
    func report() async throws -> ScanReport {
        let task = Task.detached(priority: .utility) { [locations, activity, inventoryLimit] in
            try Self.scanSynchronously(locations: locations, activity: activity, inventoryLimit: inventoryLimit)
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

    private static func scanSynchronously(locations: [Location]?, activity: @Sendable () throws -> CleanupActivity,
                                          inventoryLimit: Int) throws -> ScanReport {
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
            let discovered = GeneratedCleanupScope.discoveryRoots(home: home).flatMap { root in
                let result = GeneratedBuildDiscovery().discover(under: root)
                if result.limitReached { warnings.append(discoveryWarning(root, home: home)) }
                return result.directories
            }
            let temporary = TemporaryBuildInspector.scan(discovered: discovered, activity: currentActivity, home: home)
            wholeFolders = temporary.candidates + SimulatorInventory.candidates(activity: currentActivity, home: home) +
                ToolCacheInventory.candidates(activity: currentActivity, home: home)
            seeds += temporary.generatedRoots.map {
                Location(url: $0, name: $0.path.replacingOccurrences(of: home.path + "/", with: ""),
                    category: .build, risk: .low, reason: "Generated files only", deletionMode: .generatedFiles)
            }
        }
        var seen = Set<String>()
        let candidates = seeds.compactMap { seed -> CleanupCandidate? in
            let url = CleanupPath.fileURL(seed.url)
            guard !Task.isCancelled, seen.insert(url.path).inserted else { return nil }
            if seed.deletionMode == .generatedFiles {
                guard let rule = GeneratedCleanupScope.rule(for: url, home: home) else { return nil }
                do {
                    // This scan also offers whole folders, so idle DerivedData projects go to that rule.
                    return try GeneratedFileDeleter.inspect(url, name: seed.name, category: seed.category, rule: rule,
                        activity: currentActivity, handsOffWholeFolders: true, maximumEntries: inventoryLimit)
                } catch let limit as InventoryLimitExceeded {
                    // Nothing is offered from a partial list, but the user must know why the folder is missing.
                    warnings.append("\(seed.name) was skipped. \(limit.localizedDescription)")
                    return nil
                } catch {
                    // A missing folder or a folder in use is a normal skip.
                    return nil
                }
            }
            guard !currentActivity.contains(url) else { return nil }
            return inspect(url, name: seed.name, category: seed.category, risk: seed.risk,
                           reason: seed.reason, deletionMode: seed.deletionMode)
        }
        let offered = validated(candidates + wholeFolders).sorted { $0.size > $1.size }.prefix(100).map { $0 }
        return ScanReport(candidates: offered, warnings: Task.isCancelled ? [] : warnings)
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
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }) else {
            let values = try? root.resourceValues(forKeys: keys)
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true { total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        }
        return total
    }
}
