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
                        maximumEntries: Int = GeneratedFileInventory.defaultMaximumEntries) throws -> CleanupCandidate? {
        guard GeneratedCleanupScope.rule(for: root, home: policy.home) == rule else { return nil }
        try activity.requireIdle(root, rule: rule)
        let inventory = try GeneratedFileInventory.read(root, rule: rule, cutoff: cutoff,
            activity: GeneratedActivityScope.of(root, rule: rule, home: policy.home),
            handsOff: handsOffWholeFolders ? wholeFolderRule(activity: activity, cutoff: cutoff, home: policy.home) : { _ in false },
            maximumEntries: maximumEntries)
        guard inventory.bytes > 0 else { return nil }
        let snapshot = GeneratedCleanupSnapshot(rule: rule, cutoff: cutoff, digest: inventory.digest, fileCount: inventory.entries.count,
                                                handsOffWholeFolders: handsOffWholeFolders ? true : nil,
                                                entryFingerprints: inventory.fingerprints)
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

    /// Removes the scanned files that are still unchanged. Files that are new, changed or gone since the scan stay.
    @discardableResult
    static func delete(_ candidate: CleanupCandidate, policy: SafetyPolicy = SafetyPolicy(),
                       activity: Activity = { try CleanupActivity.capture() },
                       beforeEntry: (Int) throws -> Void = { _ in }, entryRemoved: () -> Void) throws -> CleanupRemoval {
        try policy.validate(candidate)
        guard let snapshot = candidate.generatedSnapshot else { throw SecureDeletionError.identityChanged }
        let current = try activity()
        try current.requireIdle(candidate.url, rule: snapshot.rule)
        let inventory = try GeneratedFileInventory.read(candidate.url, rule: snapshot.rule, cutoff: snapshot.cutoff,
            activity: GeneratedActivityScope.of(candidate.url, rule: snapshot.rule, home: policy.home),
            handsOff: snapshot.handsOffWholeFolders == true
                ? wholeFolderRule(activity: current, cutoff: snapshot.cutoff, home: policy.home) : { _ in false })
        guard inventory.rootIdentity == candidate.identity else { throw SecureDeletionError.identityChanged }
        let entries = try unchangedEntries(inventory, snapshot: snapshot, size: candidate.size).sorted { lhs, rhs in
            let lhsParent = lhs.parts.dropLast()
            let rhsParent = rhs.parts.dropLast()
            if !lhsParent.elementsEqual(rhsParent) {
                return lhsParent.lexicographicallyPrecedes(rhsParent)
            }
            return (lhs.parts.last ?? "") < (rhs.parts.last ?? "")
        }
        try activity().requireIdle(candidate.url, rule: snapshot.rule)
        var removedBytes: Int64 = 0, removedFiles = 0
        var lastActivityCheck = Date()
        let uid = getuid()
        var rootFD: Int32 = -1
        var currentParentParts: [String]?
        var currentParentFD: Int32 = -1
        var currentParentOriginalMode: mode_t?

        func closeCurrentParent() throws {
            let fd = currentParentFD
            let originalMode = currentParentOriginalMode
            currentParentFD = -1
            currentParentParts = nil
            currentParentOriginalMode = nil
            guard fd >= 0 else { return }
            defer { close(fd) }
            if let originalMode, fchmod(fd, originalMode) != 0 {
                throw SecureDeletionError.systemCall("Restoring compiler-cache permissions", errno)
            }
        }

        func closeRoot() {
            if rootFD >= 0 {
                close(rootFD)
                rootFD = -1
            }
        }

        defer {
            _ = try? closeCurrentParent()
            closeRoot()
        }

        do {
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                try beforeEntry(index)
                if index > 0 && Date().timeIntervalSince(lastActivityCheck) >= 2 {
                    try closeCurrentParent()
                    closeRoot()
                    try activity().requireIdle(candidate.url, rule: snapshot.rule)
                    lastActivityCheck = Date()
                }
                if rootFD < 0 {
                    rootFD = try openVerifiedRoot(for: candidate)
                }
                guard let name = entry.parts.last, !name.isEmpty else {
                    throw SecureDeletionError.identityChanged
                }
                let parentParts = Array(entry.parts.dropLast())
                if currentParentParts != parentParts || currentParentFD < 0 {
                    try closeCurrentParent()
                    currentParentFD = try openVerifiedParent(
                        from: rootFD, parentParts: parentParts[...],
                        device: candidate.identity.device, uid: uid
                    )
                    currentParentParts = parentParts
                }
                var actual = stat()
                guard fstatat(currentParentFD, name, &actual, AT_SYMLINK_NOFOLLOW) == 0,
                      actual.st_mode & S_IFMT == S_IFREG, GeneratedFileStamp(actual) == entry.stamp else {
                    throw SecureDeletionError.identityChanged
                }
                if unlinkat(currentParentFD, name, 0) != 0 {
                    let code = errno
                    var parentInfo = stat()
                    guard code == EACCES, currentParentOriginalMode == nil,
                          fstat(currentParentFD, &parentInfo) == 0, parentInfo.st_uid == uid,
                          parentInfo.st_mode & S_IWUSR == 0, parentInfo.st_flags == 0 else {
                        throw SecureDeletionError.systemCall("Removing generated file", code)
                    }
                    let original = parentInfo.st_mode & 0o7777
                    guard fchmod(currentParentFD, original | S_IWUSR) == 0 else {
                        throw SecureDeletionError.systemCall("Preparing owned compiler cache", errno)
                    }
                    currentParentOriginalMode = original
                    guard unlinkat(currentParentFD, name, 0) == 0 else {
                        throw SecureDeletionError.systemCall("Removing generated file", errno)
                    }
                }
                removedBytes += entry.stamp.allocated
                removedFiles += 1
                entryRemoved()
            }
            try closeCurrentParent()
            closeRoot()
        } catch {
            guard removedFiles > 0 else { throw error }
            throw PartialCleanupFailure(removedBytes: removedBytes, removedFiles: removedFiles, reason: error.localizedDescription)
        }
        return CleanupRemoval(removedBytes: removedBytes, skippedFiles: snapshot.fileCount - entries.count)
    }

    /// The fresh entries that the scan also listed with the same path and stamp.
    /// A snapshot without fingerprints needs the whole inventory to match, as before.
    private static func unchangedEntries(_ inventory: GeneratedFileInventory, snapshot: GeneratedCleanupSnapshot,
                                         size: Int64) throws -> [GeneratedFileEntry] {
        if inventory.digest == snapshot.digest, inventory.entries.count == snapshot.fileCount, inventory.bytes == size {
            return inventory.entries
        }
        guard let known = snapshot.knownEntries else { throw SecureDeletionError.identityChanged }
        let entries = inventory.entries.filter { known.contains($0.fingerprint) }
        guard !entries.isEmpty, entries.count <= snapshot.fileCount else { throw SecureDeletionError.identityChanged }
        return entries
    }

    private static func openVerifiedRoot(for candidate: CleanupCandidate) throws -> Int32 {
        let fd = try SecureFileDeleter.openDirectoryChain(Array(CleanupPath.fileURL(candidate.url).pathComponents.dropFirst()))
        var info = stat()
        guard fstat(fd, &info) == 0,
              FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)) == candidate.identity else {
            close(fd)
            throw SecureDeletionError.identityChanged
        }
        return fd
    }

    private static func openVerifiedParent(from rootFD: Int32, parentParts: ArraySlice<String>,
                                           device: UInt64, uid: uid_t) throws -> Int32 {
        var fd = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw SecureDeletionError.systemCall("Duplicating generated root", errno) }
        do {
            var info = stat()
            for component in parentParts {
                let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw SecureDeletionError.systemCall("Opening generated parent", errno) }
                close(fd); fd = child
                guard fstat(fd, &info) == 0, UInt64(info.st_dev) == device,
                      info.st_uid == uid else { throw SecureDeletionError.identityChanged }
            }
            return fd
        } catch { close(fd); throw error }
    }
}
