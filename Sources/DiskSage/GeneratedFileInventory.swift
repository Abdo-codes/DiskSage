import CryptoKit
import Darwin
import Foundation

struct GeneratedFileStamp: Hashable, Sendable {
    let device: dev_t, inode: ino_t, mode: mode_t
    let size: off_t, blocks: blkcnt_t
    let modified: timespec, changed: timespec, born: timespec
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        size = value.st_size; blocks = value.st_blocks
        modified = value.st_mtimespec; changed = value.st_ctimespec; born = value.st_birthtimespec
    }
    var key: String {
        "\(device):\(inode):\(mode):\(size):\(blocks):\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec):\(born.tv_sec):\(born.tv_nsec)"
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    var allocated: Int64 { max(0, Int64(blocks)) * 512 }
    func isOlder(than cutoff: Date) -> Bool {
        [modified, changed, born].allSatisfy { Double($0.tv_sec) + Double($0.tv_nsec) / 1e9 < cutoff.timeIntervalSince1970 }
    }
}

struct GeneratedFileEntry: Sendable {
    let parts: [String]
    let stamp: GeneratedFileStamp
    var path: String { parts.joined(separator: "/") }
}

struct GeneratedFileInventory: Sendable {
    let rootIdentity: FileIdentity
    let entries: [GeneratedFileEntry]
    var bytes: Int64 { entries.reduce(0) { $0 + $1.stamp.allocated } }
    var digest: String {
        var hash = SHA256()
        for entry in entries {
            let path = Data(entry.path.utf8)
            hash.update(data: Data("\(path.count):".utf8))
            hash.update(data: path)
            hash.update(data: Data(":\(entry.stamp.key)\n".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Files changed after `cutoff` are never listed. With an activity scope, any entry
    /// changed after `cutoff` also removes every file of its group from the inventory.
    static func read(_ root: URL, rule: GeneratedCleanupRule, cutoff: Date,
                     activity scope: GeneratedActivityScope = .none,
                     maximumEntries: Int = 200_000) throws -> Self {
        let parts = CleanupPath.fileURL(root).pathComponents
        let fd = try SecureFileDeleter.openDirectoryChain(Array(parts.dropFirst()))
        defer { close(fd) }
        var rootInfo = stat()
        guard fstat(fd, &rootInfo) == 0, rootInfo.st_uid == getuid() else {
            throw FeatureFailure(message: "The generated folder is not owned by the current user.")
        }
        var entries: [GeneratedFileEntry] = [], visited = 0, activeGroups = Set<String>(), freshGroups = Set<String>()
        // In Xcode's shared DerivedData, a project folder with no change for a day goes to the whole-folder rule.
        // The time comes from `cutoff`, so the scan and the deletion agree.
        let handOff = cutoff.addingTimeInterval(GeneratedCleanupPolicy.minimumAge - TemporaryBuildOutput.day)
        if let group = scope.group([]), !GeneratedFileStamp(rootInfo).isOlder(than: cutoff) { activeGroups.insert(group) }
        func walk(_ parent: Int32, _ relative: [String]) throws {
            try Task.checkCancellation()
            guard relative.count <= 128 else { throw FeatureFailure(message: "Generated-file inventory exceeded its depth limit.") }
            let duplicate = dup(parent)
            guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }
                throw SecureDeletionError.systemCall("Reading generated files", errno)
            }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw SecureDeletionError.systemCall("Reading generated files", errno) }
                    break
                }
                let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
                }
                guard let name else { throw FeatureFailure(message: "A filename could not be verified.") }
                if name == "." || name == ".." { continue }
                visited += 1
                guard visited <= maximumEntries else { throw FeatureFailure(message: "Generated-file inventory exceeded its safety limit.") }
                try Task.checkCancellation()
                let path = relative + [name]
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw SecureDeletionError.systemCall("Inspecting generated files", errno)
                }
                guard info.st_dev == rootInfo.st_dev else { throw SecureDeletionError.crossedFilesystem(path.joined(separator: "/")) }
                if let group = scope.group(path), !GeneratedFileStamp(info).isOlder(than: cutoff) { activeGroups.insert(group) }
                if scope == .perChild, let group = path.first, !GeneratedFileStamp(info).isOlder(than: handOff) { freshGroups.insert(group) }
                guard info.st_uid == getuid() else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard GeneratedCleanupPolicy.mayDescend(path) else { continue }
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw SecureDeletionError.systemCall("Opening generated folder", errno) }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                        throw SecureDeletionError.identityChanged
                    }
                    try walk(child, path)
                } else if info.st_mode & S_IFMT == S_IFREG {
                    guard info.st_nlink == 1 else { continue }
                    let stamp = GeneratedFileStamp(info)
                    guard stamp.isOlder(than: cutoff) else { continue }
                    let matches = try GeneratedCleanupPolicy.eligible(name: name, parents: relative,
                        rootName: root.lastPathComponent, rule: rule,
                        prefix: { try readFile(parent, name, expected: stamp, hash: false) },
                        checksum: { String(decoding: try readFile(parent, name, expected: stamp, hash: true), as: UTF8.self) })
                    if matches { entries.append(GeneratedFileEntry(parts: path, stamp: stamp)) }
                }
            }
        }
        try walk(fd, [])
        if !activeGroups.isEmpty {
            entries.removeAll { scope.group($0.parts).map(activeGroups.contains) ?? false }
        }
        if scope == .perChild {
            entries.removeAll { part in
                guard let group = part.parts.first else { return false }
                return TemporaryBuildOutput.isXcodeProjectFolderName(group) && !freshGroups.contains(group)
            }
        }
        return Self(rootIdentity: FileIdentity(device: UInt64(rootInfo.st_dev), inode: UInt64(rootInfo.st_ino)),
                    entries: entries.sorted { $0.path < $1.path })
    }

    private static func readFile(_ parent: Int32, _ name: String, expected: GeneratedFileStamp, hash: Bool) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SecureDeletionError.systemCall("Reading cache content", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, GeneratedFileStamp(info) == expected else { throw SecureDeletionError.identityChanged }
        var result = Data(), checksum = SHA256(), buffer = [UInt8](repeating: 0, count: hash ? 65_536 : 32)
        repeat {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SecureDeletionError.systemCall("Reading cache content", errno) }
            if count == 0 { break }
            if hash { checksum.update(data: Data(buffer.prefix(count))) }
            else { result = Data(buffer.prefix(count)); break }
        } while hash
        guard fstat(fd, &info) == 0, GeneratedFileStamp(info) == expected else { throw SecureDeletionError.identityChanged }
        return hash ? Data(checksum.finalize().map { String(format: "%02x", $0) }.joined().utf8) : result
    }
}
