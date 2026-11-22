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
        #expect(!entry.linked)
        #expect(try #require(DiskScanner.allocatedSize(of: f.base)) >= Int64(payloadSize))
    }

    @Test func hardLinksInsideOneFolderAreCountedOnce() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let original = try f.write("cache/a.bin", bytes: payloadSize)
        let hardLink = f.base.appending(path: "cache/b.bin")
        #expect(link(original.path, hardLink.path) == 0)

        let cache = f.base.appending(path: "cache")
        let single = try #require(ReclaimableSize.measure(original.path)).allocated
        let scanned = try #require(DiskScanner.allocatedSize(of: cache))
        let surveyed = try FolderSurvey.read(cache).bytes
        #expect(scanned == single)
        #expect(surveyed == single)
    }

    @Test func apfsCloneSharedOutsideFolderCountsOnlyPrivateBytes() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let outside = try f.write("keep/original.bin", bytes: payloadSize)
        let cache = try f.folder("cache")
        let cloned = cache.appending(path: "clone.bin")
        guard clonefile(outside.path, cloned.path, 0) == 0 else {
            // Non-APFS filesystem: nothing to assert about clone sharing.
            return
        }

        let entry = try #require(ReclaimableSize.measure(cloned.path))
        #expect(entry.allocated >= Int64(payloadSize))
        #expect(entry.bytes == 0)
        #expect(entry.shared == entry.allocated)
        #expect(entry.clones == 2)
        #expect(try #require(DiskScanner.allocatedSize(of: cache)) == 0)
        #expect(try FolderSurvey.read(cache).bytes == 0)
    }

    @Test func apfsClonesAllInsideSameFolderCountSharedBlocksOnce() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let first = try f.write("cache/one.bin", bytes: payloadSize)
        let second = f.base.appending(path: "cache/two.bin")
        guard clonefile(first.path, second.path, 0) == 0 else {
            return
        }

        let cache = f.base.appending(path: "cache")
        let single = try #require(ReclaimableSize.measure(first.path)).allocated
        let scanned = try #require(DiskScanner.allocatedSize(of: cache))
        let surveyed = try FolderSurvey.read(cache).bytes
        #expect(scanned == single)
        #expect(surveyed == single)
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
