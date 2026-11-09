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
    init(locations: [Location]? = nil, activity: @escaping @Sendable () throws -> CleanupActivity = { try CleanupActivity.capture() }) {
        self.locations = locations; self.activity = activity
    }

    func scan() async -> [CleanupCandidate] {
        let task = Task.detached(priority: .utility) { Self.scanSynchronously(locations: locations, activity: activity) }
        return await withTaskCancellationHandler {
            if Task.isCancelled { task.cancel() }
            let results = await task.value
            return Task.isCancelled ? [] : results
        } onCancel: { task.cancel() }
    }

    private static func scanSynchronously(locations: [Location]?, activity: @Sendable () throws -> CleanupActivity) -> [CleanupCandidate] {
        guard !Task.isCancelled else { return [] }
        // A failed/incomplete activity check never turns into permission to delete.
        guard let currentActivity = try? activity() else { return [] }
        let home = CleanupPath.fileURL(FileManager.default.homeDirectoryForCurrentUser)
        var seeds = locations ?? defaultLocations(home: home)
        var wholeFolders: [CleanupCandidate] = []
        if locations == nil {
            let discovered = GeneratedCleanupScope.discoveryRoots(home: home).flatMap { GeneratedBuildDiscovery().directories(under: $0) }
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
                // This scan also offers whole folders, so idle DerivedData projects go to that rule.
                return try? GeneratedFileDeleter.inspect(url, name: seed.name, category: seed.category,
                                                       rule: rule, activity: currentActivity, handsOffWholeFolders: true)
            }
            guard !currentActivity.contains(url) else { return nil }
            return inspect(url, name: seed.name, category: seed.category, risk: seed.risk,
                           reason: seed.reason, deletionMode: seed.deletionMode)
        }
        return validated(candidates + wholeFolders).sorted { $0.size > $1.size }.prefix(100).map { $0 }
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
