import Darwin
import Foundation

struct PartialCleanupFailure: LocalizedError {
    let removedBytes: Int64
    let removedFiles: Int
    let reason: String
    var errorDescription: String? { "Stopped after \(removedFiles) generated files: \(reason) Remaining files were kept; scan again." }
}

enum GeneratedFileDeleter {
    typealias Activity = @Sendable () throws -> CleanupActivity

    static func inspect(_ root: URL, name: String, category: CandidateCategory, rule: GeneratedCleanupRule,
                        activity: CleanupActivity, cutoff: Date = Date().addingTimeInterval(-GeneratedCleanupPolicy.minimumAge),
                        policy: SafetyPolicy = SafetyPolicy(), handsOffWholeFolders: Bool = false,
                        maximumEntries: Int = 200_000) throws -> CleanupCandidate? {
        guard GeneratedCleanupScope.rule(for: root, home: policy.home) == rule else { return nil }
        try activity.requireIdle(root, rule: rule)
        let inventory = try GeneratedFileInventory.read(root, rule: rule, cutoff: cutoff,
            activity: GeneratedActivityScope.of(root, rule: rule, home: policy.home),
            handsOff: handsOffWholeFolders ? wholeFolderRule(activity: activity, cutoff: cutoff, home: policy.home) : { _ in false },
            maximumEntries: maximumEntries)
        guard inventory.bytes > 0 else { return nil }
        let snapshot = GeneratedCleanupSnapshot(rule: rule, cutoff: cutoff, digest: inventory.digest, fileCount: inventory.entries.count,
                                                handsOffWholeFolders: handsOffWholeFolders ? true : nil)
        let candidate = CleanupCandidate(url: CleanupPath.fileURL(root), name: name, category: category,
            size: inventory.bytes, risk: .low,
            reason: "\(snapshot.fileCount) verified generated files. Recent files, source, test evidence, installed dependencies and session data stay.",
            identity: inventory.rootIdentity, deletionMode: .generatedFiles, generatedSnapshot: snapshot)
        try policy.validate(candidate)
        return candidate
    }

    /// True when the whole-folder rule offers this folder. Only a scan that also offers whole folders uses it. The time comes from `cutoff`, so the scan and the deletion agree.
    static func wholeFolderRule(activity: CleanupActivity, cutoff: Date, home: URL) -> (URL) -> Bool {
        let now = cutoff.addingTimeInterval(GeneratedCleanupPolicy.minimumAge)
        return { TemporaryBuildInspector.inspect($0, activity: activity, now: now, home: home) != nil }
    }

    static func delete(_ candidate: CleanupCandidate, policy: SafetyPolicy = SafetyPolicy(),
                       activity: Activity = { try CleanupActivity.capture() },
                       beforeEntry: (Int) throws -> Void = { _ in }, entryRemoved: () -> Void) throws {
        try policy.validate(candidate)
        guard let snapshot = candidate.generatedSnapshot else { throw SecureDeletionError.identityChanged }
        let current = try activity()
        try current.requireIdle(candidate.url, rule: snapshot.rule)
        let inventory = try GeneratedFileInventory.read(candidate.url, rule: snapshot.rule, cutoff: snapshot.cutoff,
            activity: GeneratedActivityScope.of(candidate.url, rule: snapshot.rule, home: policy.home),
            handsOff: snapshot.handsOffWholeFolders == true
                ? wholeFolderRule(activity: current, cutoff: snapshot.cutoff, home: policy.home) : { _ in false })
        guard inventory.rootIdentity == candidate.identity, inventory.digest == snapshot.digest,
              inventory.entries.count == snapshot.fileCount, inventory.bytes == candidate.size else {
            throw SecureDeletionError.identityChanged
        }
        try activity().requireIdle(candidate.url, rule: snapshot.rule)
        var removedBytes: Int64 = 0, removedFiles = 0
        var lastActivityCheck = Date()
        do {
            for (index, entry) in inventory.entries.enumerated() {
                try Task.checkCancellation()
                try beforeEntry(index)
                if index > 0 && Date().timeIntervalSince(lastActivityCheck) >= 2 {
                    try activity().requireIdle(candidate.url, rule: snapshot.rule)
                    lastActivityCheck = Date()
                }
                let parent = try verifiedParent(candidate, parts: entry.parts)
                defer { close(parent) }
                var actual = stat()
                guard let name = entry.parts.last,
                      fstatat(parent, name, &actual, AT_SYMLINK_NOFOLLOW) == 0,
                      actual.st_mode & S_IFMT == S_IFREG, GeneratedFileStamp(actual) == entry.stamp else {
                    throw SecureDeletionError.identityChanged
                }
                try unlinkGenerated(parent: parent, name: name, removed: {
                    removedBytes += entry.stamp.allocated; removedFiles += 1; entryRemoved()
                })
            }
        } catch {
            guard removedFiles > 0 else { throw error }
            throw PartialCleanupFailure(removedBytes: removedBytes, removedFiles: removedFiles, reason: error.localizedDescription)
        }
    }

    private static func verifiedParent(_ candidate: CleanupCandidate, parts: [String]) throws -> Int32 {
        var fd = try SecureFileDeleter.openDirectoryChain(Array(CleanupPath.fileURL(candidate.url).pathComponents.dropFirst()))
        do {
            var info = stat()
            guard fstat(fd, &info) == 0,
                  FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)) == candidate.identity else {
                throw SecureDeletionError.identityChanged
            }
            for component in parts.dropLast() {
                let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw SecureDeletionError.systemCall("Opening generated parent", errno) }
                close(fd); fd = child
                guard fstat(fd, &info) == 0, UInt64(info.st_dev) == candidate.identity.device,
                      info.st_uid == getuid() else { throw SecureDeletionError.identityChanged }
            }
            return fd
        } catch { close(fd); throw error }
    }

    /// Read-only compiler output directories are common. Never change ACLs, flags or another user's permissions.
    private static func unlinkGenerated(parent: Int32, name: String, removed: () -> Void) throws {
        if unlinkat(parent, name, 0) == 0 { removed(); return }
        let code = errno
        var info = stat()
        guard code == EACCES, fstat(parent, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IWUSR == 0, info.st_flags == 0 else {
            throw SecureDeletionError.systemCall("Removing generated file", code)
        }
        let original = info.st_mode & 0o7777
        guard fchmod(parent, original | S_IWUSR) == 0 else {
            throw SecureDeletionError.systemCall("Preparing owned compiler cache", errno)
        }
        let status = unlinkat(parent, name, 0), removalCode = errno
        if status == 0 { removed() }
        let restored = fchmod(parent, original), restoreCode = errno
        guard restored == 0 else { throw SecureDeletionError.systemCall("Restoring compiler-cache permissions", restoreCode) }
        guard status == 0 else { throw SecureDeletionError.systemCall("Removing generated file", removalCode) }
    }
}
