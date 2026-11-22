import Darwin
import Foundation
import Testing
@testable import DiskSage

struct ReclaimableSizeTests {
    private let payloadSize = 256 * 1024

    @Test func regularFileReportsAllocatedBytes() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let file = try f.write("payload.bin", bytes: payloadSize)
        let entry = try #require(ReclaimableSize.measure(file.path))
        #expect(entry.bytes >= Int64(payloadSize))
        #expect(entry.allocated >= Int64(payloadSize))
        #expect(entry.linkCount == 1)
        #expect(try #require(DiskScanner.allocatedSize(of: f.base)) >= Int64(payloadSize))
    }

    @Test func hardLinksCountOnceWhenAllInsideAndZeroWhenSharedOutside() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let original = try f.write("cache/a.bin", bytes: payloadSize)
        let sibling = f.base.appending(path: "cache/b.bin")
        #expect(link(original.path, sibling.path) == 0)

        let cache = f.base.appending(path: "cache")
        let single = try #require(ReclaimableSize.measure(original.path)).allocated
        #expect(try #require(DiskScanner.allocatedSize(of: cache)) == single)
        #expect(try FolderSurvey.read(cache).bytes == single)

        // Adding a hard link outside `cache` means deleting `cache` frees nothing for this inode.
        let outside = try f.folder("keep").appending(path: "c.bin")
        #expect(link(original.path, outside.path) == 0)
        #expect(try #require(DiskScanner.allocatedSize(of: cache)) == 0)
        #expect(try FolderSurvey.read(cache).bytes == 0)
    }

    @Test func apfsCloneSharedOutsideFolderCountsOnlyPrivateBytes() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let outside = try f.write("keep/original.bin", bytes: payloadSize)
        let cache = try f.folder("cache")
        let cloned = cache.appending(path: "clone.bin")
        guard clonefile(outside.path, cloned.path, 0) == 0 else { return }

        let entry = try #require(ReclaimableSize.measure(cloned.path))
        #expect(entry.allocated >= Int64(payloadSize))
        #expect(entry.bytes == 0)
        #expect(try #require(DiskScanner.allocatedSize(of: cache)) == 0)
        #expect(try FolderSurvey.read(cache).bytes == 0)
    }

    @Test func externalPartialClonePreventsOverstatingReclaimableSpace() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let block = 64 * 1024
        let cache = try f.folder("cache")
        let outside = try f.folder("keep")
        // Create A=[X, Y], clone to B outside and overwrite B's first block to [Z, Y], then clone A to C inside.
        let a = try f.write("cache/a.bin", bytes: block * 2)
        let b = outside.appending(path: "b.bin")
        guard clonefile(a.path, b.path, 0) == 0 else { return }
        let handle = try FileHandle(forUpdating: b)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 9, count: block))
        try handle.close()
        let c = cache.appending(path: "c.bin")
        guard clonefile(a.path, c.path, 0) == 0 else { return }

        // Even though A and C are all full clones in their CLONEID group, B outside still retains Y.
        // Conservative lower-bound sizing never overstates space (deleting cache frees at most 1 block, X).
        let scanned = try #require(DiskScanner.allocatedSize(of: cache))
        let surveyed = try FolderSurvey.read(cache).bytes
        #expect(scanned <= Int64(block))
        #expect(surveyed <= Int64(block))
        // B's own uniquely overwritten block Z is still counted as private bytes.
        #expect(try #require(ReclaimableSize.measure(b.path)).bytes == Int64(block))
    }

    @Test func clonedVideoStillFlagsMediaBytesInFolderSurvey() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let outside = try f.write("keep/clip.mov", bytes: payloadSize)
        let cache = try f.folder("cache")
        let cloned = cache.appending(path: "clip.mov")
        guard clonefile(outside.path, cloned.path, 0) == 0 else { return }

        let survey = try FolderSurvey.read(cache)
        #expect(survey.bytes == 0)
        #expect(survey.mediaBytes >= Int64(payloadSize))
    }

    @Test func symlinksAreIgnored() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let target = try f.write("target.bin", bytes: payloadSize)
        let linkURL = f.base.appending(path: "cache/link.bin")
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)

        #expect(ReclaimableSize.measure(linkURL.path) == nil)
        #expect(try #require(DiskScanner.allocatedSize(of: f.base.appending(path: "cache"))) == 0)
    }
}
