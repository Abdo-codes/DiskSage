import Darwin
import Foundation

/// Measures the disk bytes that deleting a set of files can reclaim on macOS.
/// Uses `getattrlist(2)` so APFS clones count only their unshared private blocks
/// (unless every clone in a family is inside the same set, in which case the union
/// of physical extents across the family is counted via `F_LOG2PHYS_EXT`, falling back
/// to a lower-bound `private + max(shared)` estimate when extents cannot be read),
/// and hard-linked files are counted at most once.
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
            var privateSum: Int64 = 0
            var members: [(path: String, allocated: Int64)] = []
        }

        private var privateTotal: Int64 = 0
        private var seenInodes: Set<Inode> = []
        private var families: [CloneFamily: FamilyState] = [:]

        /// Total reclaimable bytes, including shared blocks for clone families
        /// whose every member was seen in this tally. Physical extents are unioned
        /// per device across complete clone families so blocks shared between diverged
        /// sub-families are never double-counted.
        var total: Int64 {
            var sum = privateTotal
            var completeMembersByDevice: [UInt64: [(path: String, allocated: Int64)]] = [:]
            var completePrivateByDevice: [UInt64: Int64] = [:]
            var fallbackSharedByDevice: [UInt64: Int64] = [:]

            for (family, state) in families where state.found >= state.clones {
                completeMembersByDevice[family.device, default: []].append(contentsOf: state.members)
                completePrivateByDevice[family.device, default: 0] += state.privateSum
                fallbackSharedByDevice[family.device, default: 0] += state.shared
            }

            for (device, members) in completeMembersByDevice {
                if let unionBytes = ReclaimableSize.physicalExtentUnionBytes(for: members) {
                    sum = sum - (completePrivateByDevice[device] ?? 0) + unionBytes
                } else {
                    sum += fallbackSharedByDevice[device] ?? 0
                }
            }
            return sum
        }

        @discardableResult
        mutating func add(path: String) -> Entry? {
            guard let entry = ReclaimableSize.measure(path) else { return nil }
            add(entry, path: path)
            return entry
        }

        mutating func add(_ entry: Entry, path: String? = nil) {
            if entry.linked && !seenInodes.insert(entry.id).inserted {
                return
            }
            privateTotal += entry.bytes
            guard let family = entry.family, entry.clones >= 2, entry.shared > 0 else { return }
            var state = families[family] ?? FamilyState(clones: entry.clones)
            state.found += 1
            state.shared = max(state.shared, entry.shared)
            state.privateSum += entry.bytes
            if let path { state.members.append((path: path, allocated: entry.allocated)) }
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
    private static let maximumExtentsPerFile = 4_096

    /// Measures one regular file without following symlinks. Returns nil for non-regular files or failures.
    static func measure(_ path: String) -> Entry? {
        if let entry = measureWithGetAttrList(path) {
            return entry
        }
        return measureWithLstat(path)
    }

    /// Computes the union of physical byte ranges across all members of a clone family using `F_LOG2PHYS_EXT`.
    /// Returns nil if any member's extents cannot be inspected cleanly, so callers fall back to `private + max(shared)`.
    static func physicalExtentUnionBytes(for members: [(path: String, allocated: Int64)]) -> Int64? {
        guard !members.isEmpty else { return nil }
        var intervals: [(start: Int64, end: Int64)] = []
        for member in members {
            guard let extents = physicalExtents(of: member.path, allocated: member.allocated) else { return nil }
            intervals.append(contentsOf: extents)
        }
        guard !intervals.isEmpty else { return 0 }
        intervals.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var total: Int64 = 0
        var currentStart = intervals[0].start
        var currentEnd = intervals[0].end
        for interval in intervals.dropFirst() {
            if interval.start <= currentEnd {
                currentEnd = max(currentEnd, interval.end)
            } else {
                total += currentEnd - currentStart
                currentStart = interval.start
                currentEnd = interval.end
            }
        }
        total += currentEnd - currentStart
        return total
    }

    private static func physicalExtents(of path: String, allocated: Int64) -> [(start: Int64, end: Int64)]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let limit = max(Int64(info.st_size), allocated)
        guard limit > 0 else { return [] }
        var extents: [(start: Int64, end: Int64)] = []
        var offset: Int64 = 0
        var steps = 0
        while offset < limit {
            steps += 1
            guard steps <= maximumExtentsPerFile else { return nil }
            var query = log2phys(l2p_flags: 0, l2p_contigbytes: limit - offset, l2p_devoffset: offset)
            guard fcntl(fd, F_LOG2PHYS_EXT, &query) == 0 else { return nil }
            let length = Int64(query.l2p_contigbytes)
            guard length > 0 else { break }
            if query.l2p_devoffset >= 0 {
                let start = Int64(query.l2p_devoffset)
                extents.append((start: start, end: start + length))
            }
            offset += length
        }
        if allocated > 0 && extents.isEmpty { return nil }
        return extents
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
