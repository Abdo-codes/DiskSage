import Darwin
import Foundation

/// Measures a conservative lower bound of the disk bytes that deleting a set of files can reclaim
/// on macOS. Uses `getattrlist(2)` so APFS clones count only their exclusively owned private blocks
/// (`ATTR_CMNEXT_PRIVATESIZE`), and hard-linked files count once only when every link to the inode
/// (`ATTR_FILE_LINKCOUNT`) lies inside the measured set.
///
/// APFS's `ATTR_CMNEXT_CLONE_REFCNT` tracks only full clones and cannot rule out external partial
/// clones retaining individual extents, so shared clone extents are intentionally excluded to avoid
/// overstating reclaimable space.
enum ReclaimableSize {
    struct Inode: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    struct Entry: Sendable {
        let bytes: Int64
        let allocated: Int64
        let id: Inode
        let linkCount: UInt32
    }

    struct Tally: Sendable {
        private struct LinkedState: Sendable {
            var seen: UInt32 = 0
            let linkCount: UInt32
            let bytes: Int64
        }

        private var unlinkedTotal: Int64 = 0
        private var linkedInodes: [Inode: LinkedState] = [:]

        /// Total conservatively reclaimable bytes: all exclusively owned bytes of single-link files
        /// plus each hard-linked inode whose every link was seen in this tally.
        var total: Int64 {
            var sum = unlinkedTotal
            for state in linkedInodes.values where state.seen >= state.linkCount {
                sum += state.bytes
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
            if entry.linkCount <= 1 {
                unlinkedTotal += entry.bytes
                return
            }
            linkedInodes[entry.id, default: LinkedState(linkCount: entry.linkCount, bytes: entry.bytes)].seen += 1
        }
    }

    private static let requiredCommonAttrs = UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
    private static let requestedCommonAttrs = UInt32(ATTR_CMN_RETURNED_ATTRS) | requiredCommonAttrs | UInt32(ATTR_CMN_FLAGS)
    private static let requiredFileAttrs = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
    private static let requestedForkAttrs = UInt32(ATTR_CMNEXT_PRIVATESIZE)
    private static let options = UInt32(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED)
    private static let expectedPayloadSize = 64
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

            guard objectType == UInt32(VREG.rawValue), allocated >= 0 else { return nil }
            let id = Inode(device: UInt64(bitPattern: Int64(device)), inode: fileID)

            let hasPrivate = (returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE)) != 0
            let isCompressed = (flags & UInt32(UF_COMPRESSED)) != 0
            let reclaimable = (hasPrivate && !isCompressed && privateBytes >= 0 && privateBytes <= allocated)
                ? privateBytes : allocated
            return Entry(bytes: reclaimable, allocated: allocated, id: id, linkCount: linkCount)
        }
    }

    private static func measureWithLstat(_ path: String) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let allocated = max(0, Int64(info.st_blocks)) * 512
        let id = Inode(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
        return Entry(bytes: allocated, allocated: allocated, id: id, linkCount: UInt32(info.st_nlink))
    }
}
