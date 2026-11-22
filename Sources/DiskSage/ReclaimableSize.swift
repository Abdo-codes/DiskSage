import Darwin
import Foundation

/// Measures the disk bytes that deleting a set of files can reclaim on macOS.
/// Uses `getattrlist(2)` so APFS clones count only their unshared private blocks
/// (unless every clone in a family is inside the same set, in which case shared
/// blocks are counted once), and hard-linked files are counted at most once.
enum ReclaimableSize {
    struct Inode: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    struct CloneFamily: Hashable, Sendable {
        let device: UInt64
        let id: UInt64
    }

    struct Entry: Sendable {
        let bytes: Int64
        let allocated: Int64
        let id: Inode
        let linked: Bool
        let family: CloneFamily?
        let clones: UInt32
        let shared: Int64
    }

    struct Tally: Sendable {
        private struct FamilyState: Sendable {
            var found: UInt32 = 0
            let clones: UInt32
            var shared: Int64 = 0
        }

        private var privateTotal: Int64 = 0
        private var seenInodes: Set<Inode> = []
        private var families: [CloneFamily: FamilyState] = [:]

        /// Total reclaimable bytes, including shared blocks for clone families
        /// whose every member was seen in this tally.
        var total: Int64 {
            var sum = privateTotal
            for state in families.values where state.found >= state.clones {
                sum += state.shared
            }
            return sum
        }

        @discardableResult
        mutating func add(path: String) -> Entry? {
            guard let entry = ReclaimableSize.measure(path) else { return nil }
            add(entry)
            return entry
        }

        mutating func add(_ entry: Entry) {
            if entry.linked && !seenInodes.insert(entry.id).inserted {
                return
            }
            privateTotal += entry.bytes
            guard let family = entry.family, entry.clones >= 2, entry.shared > 0 else { return }
            var state = families[family] ?? FamilyState(clones: entry.clones)
            state.found += 1
            state.shared = max(state.shared, entry.shared)
            families[family] = state
        }
    }

    private static let requiredCommonAttrs = UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
    private static let requestedCommonAttrs = UInt32(ATTR_CMN_RETURNED_ATTRS) | requiredCommonAttrs | UInt32(ATTR_CMN_FLAGS)
    private static let requiredFileAttrs = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
    private static let requestedForkAttrs = UInt32(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
    private static let options = UInt32(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED)
    private static let expectedPayloadSize = 76
    private static let bufferSize = 128

    /// Measures one regular file without following symlinks. Returns nil for non-regular files or failures.
    static func measure(_ path: String) -> Entry? {
        if let entry = measureWithGetAttrList(path) {
            return entry
        }
        return measureWithLstat(path)
    }

    private static func measureWithGetAttrList(_ path: String) -> Entry? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = requestedCommonAttrs
        list.fileattr = requiredFileAttrs
        list.forkattr = requestedForkAttrs

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let status = path.withCString { pointer in
            buffer.withUnsafeMutableBytes { raw in
                getattrlist(pointer, &list, raw.baseAddress, raw.count, options)
            }
        }
        guard status == 0 else { return nil }
        return parseAttrBuffer(buffer)
    }

    /// Parses the fixed-layout buffer returned by `getattrlist` with `FSOPT_PACK_INVAL_ATTRS`.
    static func parseAttrBuffer(_ buffer: [UInt8]) -> Entry? {
        guard buffer.count >= expectedPayloadSize else { return nil }
        return buffer.withUnsafeBytes { raw -> Entry? in
            let length = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            guard length >= expectedPayloadSize, length <= buffer.count else { return nil }

            let returnedCommon = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let returnedFile = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            let returnedFork = raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            guard (returnedCommon & requiredCommonAttrs) == requiredCommonAttrs,
                  (returnedFile & requiredFileAttrs) == requiredFileAttrs else { return nil }

            let device = raw.loadUnaligned(fromByteOffset: 24, as: Int32.self)
            let objectType = raw.loadUnaligned(fromByteOffset: 28, as: UInt32.self)
            let flags = (returnedCommon & UInt32(ATTR_CMN_FLAGS)) != 0
                ? raw.loadUnaligned(fromByteOffset: 32, as: UInt32.self) : 0
            let fileID = raw.loadUnaligned(fromByteOffset: 36, as: UInt64.self)
            let linkCount = raw.loadUnaligned(fromByteOffset: 44, as: UInt32.self)
            let allocated = raw.loadUnaligned(fromByteOffset: 48, as: Int64.self)
            let privateBytes = raw.loadUnaligned(fromByteOffset: 56, as: Int64.self)
            let cloneID = raw.loadUnaligned(fromByteOffset: 64, as: UInt64.self)
            let cloneRefCount = raw.loadUnaligned(fromByteOffset: 72, as: UInt32.self)

            guard objectType == UInt32(VREG.rawValue), allocated >= 0 else { return nil }
            let dev = UInt64(bitPattern: Int64(device))
            let id = Inode(device: dev, inode: fileID)
            let linked = linkCount > 1

            let hasPrivate = (returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE)) != 0
            let isCompressed = (flags & UInt32(UF_COMPRESSED)) != 0
            guard hasPrivate, !isCompressed, privateBytes >= 0, privateBytes <= allocated else {
                return Entry(bytes: allocated, allocated: allocated, id: id, linked: linked,
                             family: nil, clones: 0, shared: 0)
            }

            let hasCloneInfo = (returnedFork & UInt32(ATTR_CMNEXT_CLONEID)) != 0 &&
                (returnedFork & UInt32(ATTR_CMNEXT_CLONE_REFCNT)) != 0 &&
                cloneRefCount > 1
            let family = hasCloneInfo ? CloneFamily(device: dev, id: cloneID) : nil
            let shared = hasCloneInfo ? (allocated - privateBytes) : 0
            return Entry(bytes: privateBytes, allocated: allocated, id: id, linked: linked,
                         family: family, clones: hasCloneInfo ? cloneRefCount : 0, shared: shared)
        }
    }

    private static func measureWithLstat(_ path: String) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let allocated = max(0, Int64(info.st_blocks)) * 512
        let id = Inode(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
        return Entry(bytes: allocated, allocated: allocated, id: id, linked: info.st_nlink > 1,
                     family: nil, clones: 0, shared: 0)
    }
}
