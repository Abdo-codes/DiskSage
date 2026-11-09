import Foundation
@testable import DiskSage

/// Folders under a fresh `/private/tmp/DS-temporary-<uuid>` folder. File times cannot be
/// moved back, so tests move "now" forward instead.
struct TemporaryBuildFixture {
    let base: URL
    let home = URL(fileURLWithPath: "/Users/disksage-fixture", isDirectory: true)
    let start = Date()

    init(base: URL = TemporaryBuildOutput.temporaryRoot.appending(path: "DS-temporary-\(UUID())")) throws {
        self.base = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func later(hours: Double) -> Date { start.addingTimeInterval(hours * 3_600) }

    @discardableResult func write(_ path: String, bytes: Int = 4_096) throws -> URL {
        let url = base.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func folder(_ path: String) throws -> URL {
        let url = base.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return CleanupPath.fileURL(url)
    }

    /// The layout `xcodebuild -derivedDataPath` leaves.
    func derivedData(_ path: String) throws -> URL {
        for file in ["info.plist", "Build/Products/Debug/App.app/App", "Build/Intermediates.noindex/a.o",
                     "Logs/Build/run.xcactivitylog", "ModuleCache.noindex/a.pcm"] {
            try write("\(path)/\(file)")
        }
        return CleanupPath.fileURL(base.appending(path: path))
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
