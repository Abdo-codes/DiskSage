import Darwin
import Foundation

enum SecureDeletionError: LocalizedError {
    case systemCall(String, Int32)
    case identityChanged
    case crossedFilesystem(String)
    case simulatorCommandFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .systemCall(operation, code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        case .identityChanged:
            "The item changed after scanning. Scan again before deleting it."
        case let .crossedFilesystem(path):
            "Refused to cross into another mounted filesystem at \(path)."
        case let .simulatorCommandFailed(status):
            "simctl failed with status \(status)."
        }
    }
}

enum CleanupProgress: Equatable, Sendable {
    case entriesRemoved(Int)
    case started(CleanupCandidate, completed: Int, total: Int)
    case finished(CleanupItemResult, completed: Int, total: Int)
}

typealias CleanupAction = @Sendable ([CleanupCandidate], CleanupTrigger,
    @escaping @Sendable (CleanupProgress) async -> Void) async -> CleanupReport

struct CleanupService: Sendable {
    // A remover calls entryRemoved synchronously on its own worker. It must not retain the callback.
    // A remover returns nil when it removed the candidate as scanned, or what it really removed.
    typealias Remove = @Sendable (CleanupCandidate, @escaping @Sendable () -> Void) throws -> CleanupRemoval?
    typealias WriteEvent = @Sendable (CleanupLogEvent) throws -> Void
    let logger: CleanupLogger
    let maximumWorkers: Int
    let remove: Remove
    let writeEvent: WriteEvent

    init(logger: CleanupLogger = .shared, maximumWorkers: Int = 4,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         now: @escaping @Sendable () -> Date = Date.init,
         activity: @escaping @Sendable () throws -> CleanupActivity = { try CleanupActivity.capture() },
         remove: Remove? = nil, writeEvent: WriteEvent? = nil) {
        let home = CleanupPath.fileURL(home)
        self.logger = logger
        self.maximumWorkers = min(4, max(1, maximumWorkers))
        self.remove = remove ?? { candidate, entryRemoved in
            // Read the kind before the policy check. A folder that stops matching after the check,
            // such as older device symbols whose newer version was deleted, still gets the full check and fails it.
            let wholeFolder = candidate.deletionMode == .item && TemporaryBuildOutput.kind(of: candidate.url, home: home) != nil
            let ecosystemCache = candidate.deletionMode == .contents && EcosystemCacheInventory.matching(candidate.url, home: home) != nil
            let currentDate = now()
            try SafetyPolicy(home: home, now: currentDate).validate(candidate)
            if candidate.deletionMode == .generatedFiles {
                return try GeneratedFileDeleter.delete(candidate, policy: SafetyPolicy(home: home, now: currentDate), activity: activity, now: now, entryRemoved: entryRemoved)
            } else if candidate.deletionMode == .simulatorDevice {
                try SimulatorInventory.delete(candidate, activity: try activity(), home: home)
            } else if candidate.deletionMode == .simulatorRuntime {
                try SimulatorRuntimeInventory.delete(candidate, activity: try activity(), home: home)
            } else if candidate.deletionMode == .toolCommand {
                return try ToolCacheInventory.clean(candidate, activity: try activity(), home: home)
            } else if candidate.deletionMode == .projectCache {
                let currentActivity = try activity()
                try ProjectCacheInventory.verifyBeforeDeletion(candidate, activity: currentActivity, now: currentDate, home: home)
                try SecureFileDeleter.delete(candidate, entryRemoved: entryRemoved)
            } else {
                let currentActivity = try activity()
                try currentActivity.requireIdle(candidate.url)
                if ecosystemCache || EcosystemCacheInventory.matching(candidate.url, home: home) != nil {
                    try EcosystemCacheInventory.verifyBeforeDeletion(candidate, activity: currentActivity, now: currentDate, home: home)
                } else if wholeFolder || TemporaryBuildOutput.kind(of: candidate.url, home: home) != nil {
                    try TemporaryBuildInspector.verifyBeforeDeletion(candidate, activity: currentActivity, now: currentDate, home: home)
                }
                try SecureFileDeleter.delete(candidate, entryRemoved: entryRemoved)
            }
            return nil
        }
        self.writeEvent = writeEvent ?? { try logger.append($0) }
    }

    func delete(_ candidates: [CleanupCandidate], trigger: CleanupTrigger = .manual,
                progress: @escaping @Sendable (CleanupProgress) async -> Void = { _ in }) async -> CleanupReport {
        let (updates, continuation) = AsyncStream<CleanupProgress>.makeStream()
        let reporting = Task { for await update in updates { await progress(update) } }
        let report = await CleanupScheduler(service: self, candidates: candidates, trigger: trigger,
                                            updates: continuation).run()
        continuation.finish()
        await reporting.value
        return report
    }
}

enum SecureFileDeleter {
    static func delete(_ candidate: CleanupCandidate, entryRemoved: () -> Void) throws {
        let components = CleanupPath.fileURL(candidate.url).pathComponents
        guard components.count > 1, let targetName = components.last else {
            throw SafetyPolicyError.refused("Refused an unsafe root path.")
        }

        let parentFD = try openDirectoryChain(Array(components.dropFirst().dropLast()))
        defer { close(parentFD) }

        var targetInfo = stat()
        guard fstatat(parentFD, targetName, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureDeletionError.systemCall("Inspecting \(candidate.url.path)", errno)
        }
        guard UInt64(targetInfo.st_dev) == candidate.identity.device,
              UInt64(targetInfo.st_ino) == candidate.identity.inode else {
            throw SecureDeletionError.identityChanged
        }
        guard (targetInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw SafetyPolicyError.refused("Cleanup targets must be directories.")
        }

        let targetFD = openat(parentFD, targetName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard targetFD >= 0 else {
            throw SecureDeletionError.systemCall("Opening \(candidate.url.path)", errno)
        }
        defer { close(targetFD) }

        var openedInfo = stat()
        guard fstat(targetFD, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFDIR,
              UInt64(openedInfo.st_dev) == candidate.identity.device,
              UInt64(openedInfo.st_ino) == candidate.identity.inode else {
            throw SecureDeletionError.identityChanged
        }

        try removeChildren(of: targetFD, device: openedInfo.st_dev, displayPath: candidate.url.path, entryRemoved: entryRemoved)

        if candidate.deletionMode == .item || candidate.deletionMode == .projectCache {
            if unlinkat(parentFD, targetName, AT_REMOVEDIR) != 0 {
                let code = errno
                guard code == EACCES, let original = makeOwnedDirectoryWritable(parentFD) else {
                    throw SecureDeletionError.systemCall("Removing \(candidate.url.path)", code)
                }
                let status = unlinkat(parentFD, targetName, AT_REMOVEDIR), removalCode = errno
                let restored = fchmod(parentFD, original), restoreCode = errno
                guard restored == 0 else {
                    throw SecureDeletionError.systemCall("Restoring permissions on parent of \(candidate.url.path)", restoreCode)
                }
                guard status == 0 else {
                    throw SecureDeletionError.systemCall("Removing \(candidate.url.path)", removalCode)
                }
            }
            entryRemoved()
        }
    }

    /// Read-only cache directories (e.g., Go module cache / SwiftPM downloads) are common.
    /// Never change ACLs, flags, or another user's permissions.
    private static func makeOwnedDirectoryWritable(_ fd: Int32) -> mode_t? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IWUSR == 0, info.st_flags == 0 else { return nil }
        let original = info.st_mode & 0o7777
        guard fchmod(fd, original | S_IWUSR) == 0 else { return nil }
        return original
    }

    static func openDirectoryChain(_ components: [String]) throws -> Int32 {
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else {
            throw SecureDeletionError.systemCall("Opening filesystem root", errno)
        }

        for component in components {
            let nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if nextFD < 0 {
                let code = errno
                close(currentFD)
                throw SecureDeletionError.systemCall("Opening path component \(component)", code)
            }
            close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    private static func removeChildren(of directoryFD: Int32, device: dev_t, displayPath: String, entryRemoved: () -> Void) throws {
        let duplicateFD = dup(directoryFD)
        guard duplicateFD >= 0, let directory = fdopendir(duplicateFD) else {
            if duplicateFD >= 0 { close(duplicateFD) }
            throw SecureDeletionError.systemCall("Reading \(displayPath)", errno)
        }
        defer { closedir(directory) }

        var restoredMode: mode_t?
        defer { if let original = restoredMode { _ = fchmod(directoryFD, original) } }

        func unlinkEntry(_ name: String, flags: Int32) throws {
            if unlinkat(directoryFD, name, flags) == 0 { return }
            let code = errno
            guard code == EACCES, restoredMode == nil,
                  let original = makeOwnedDirectoryWritable(directoryFD) else {
                throw SecureDeletionError.systemCall("Removing \(displayPath)/\(name)", code)
            }
            restoredMode = original
            guard unlinkat(directoryFD, name, flags) == 0 else {
                throw SecureDeletionError.systemCall("Removing \(displayPath)/\(name)", errno)
            }
        }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 {
                    throw SecureDeletionError.systemCall("Reading \(displayPath)", errno)
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SecureDeletionError.systemCall("Inspecting \(displayPath)/\(name)", errno)
            }

            if (info.st_mode & S_IFMT) == S_IFDIR {
                guard info.st_dev == device else {
                    throw SecureDeletionError.crossedFilesystem("\(displayPath)/\(name)")
                }
                let childFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else {
                    throw SecureDeletionError.systemCall("Opening \(displayPath)/\(name)", errno)
                }
                do {
                    var opened = stat()
                    guard fstat(childFD, &opened) == 0 else {
                        throw SecureDeletionError.systemCall("Inspecting \(displayPath)/\(name)", errno)
                    }
                    guard opened.st_dev == device else {
                        throw SecureDeletionError.crossedFilesystem("\(displayPath)/\(name)")
                    }
                    guard (opened.st_mode & S_IFMT) == S_IFDIR, opened.st_ino == info.st_ino else {
                        throw SecureDeletionError.identityChanged
                    }
                    try removeChildren(of: childFD, device: device, displayPath: "\(displayPath)/\(name)", entryRemoved: entryRemoved)
                    close(childFD)
                } catch {
                    close(childFD)
                    throw error
                }
                try unlinkEntry(name, flags: AT_REMOVEDIR)
            } else {
                try unlinkEntry(name, flags: 0)
            }
            entryRemoved()
        }

        if let original = restoredMode {
            restoredMode = nil
            guard fchmod(directoryFD, original) == 0 else {
                throw SecureDeletionError.systemCall("Restoring permissions on \(displayPath)", errno)
            }
        }
    }
}
