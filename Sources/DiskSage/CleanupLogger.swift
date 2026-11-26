import Foundation

enum CleanupTrigger: String, Codable, Sendable {
    case manual
    case automatic
    case agent
    case scheduled

    var title: String {
        switch self {
        case .manual: "Manual"
        case .automatic: "Automatic"
        case .agent: "Agent"
        case .scheduled: "Scheduled"
        }
    }
}

struct CleanupLogEvent: Equatable, Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case check
        case started
        case itemStarted
        case itemFinished
        case finished
    }

    var timestamp = Date()
    let runID: UUID
    let trigger: CleanupTrigger
    let event: Kind
    var path: String?
    var name: String?
    var succeeded: Bool?
    var message: String?
    var estimatedRemovedBytes: Int64?
    var actualRecoveredBytes: Int64?
    var freeSpaceBefore: Int64?
    var freeSpaceAfter: Int64?
    var candidateCount: Int?
    var failedCount: Int?
    var removedEntryCount: Int?
    var id: String { "\(runID.uuidString):\(event.rawValue):\(path ?? "")" }
}

final class CleanupLogger: @unchecked Sendable {
    static let shared = CleanupLogger(directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/DiskSage", directoryHint: .isDirectory))

    private struct FileStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: off_t
        let mtimeSec: Int
        let mtimeNsec: Int

        static func read(path: String) -> FileStamp? {
            var info = Darwin.stat()
            guard stat(path, &info) == 0 else { return nil }
            return FileStamp(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                size: info.st_size,
                mtimeSec: info.st_mtimespec.tv_sec,
                mtimeNsec: info.st_mtimespec.tv_nsec
            )
        }
    }

    private struct RecentCleanupCache {
        let previousStamp: FileStamp?
        let currentStamp: FileStamp?
        let limit: Int
        let summaries: [CleanupRunSummary]
    }

    private static let finishedMarker = Data("\"finished\"".utf8)
    private static let itemFinishedMarker = Data("\"itemFinished\"".utf8)

    let directory: URL
    var fileURL: URL { directory.appending(path: "cleanup.jsonl") }
    private var previousFileURL: URL { directory.appending(path: "cleanup.previous.jsonl") }
    private let maximumBytes: UInt64
    private let lock = NSLock()
    private var recentCache: RecentCleanupCache?

    init(directory: URL, maximumBytes: UInt64 = 5 * 1_024 * 1_024) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    func recentCleanups(limit: Int = 20) throws -> [CleanupRunSummary] {
        lock.lock()
        defer { lock.unlock() }
        let clampedLimit = max(0, limit)
        let previousStamp = FileStamp.read(path: previousFileURL.path)
        let currentStamp = FileStamp.read(path: fileURL.path)
        if let cache = recentCache,
           cache.previousStamp == previousStamp,
           cache.currentStamp == currentStamp,
           cache.limit >= clampedLimit {
            return Array(cache.summaries.prefix(clampedLimit))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [CleanupLogEvent] = []
        for url in [previousFileURL, fileURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            events += data.split(separator: 0x0A).compactMap { line in
                guard data.range(of: Self.finishedMarker, in: line.startIndex..<line.endIndex) != nil
                    || data.range(of: Self.itemFinishedMarker, in: line.startIndex..<line.endIndex) != nil else {
                    return nil
                }
                return try? decoder.decode(CleanupLogEvent.self, from: Data(line))
            }
        }
        let summaries = CleanupHistory.summaries(from: events, limit: clampedLimit)
        recentCache = RecentCleanupCache(
            previousStamp: previousStamp,
            currentStamp: currentStamp,
            limit: clampedLimit,
            summaries: summaries
        )
        return summaries
    }

    func append(_ event: CleanupLogEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        let manager = FileManager.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)

        var rotated = false
        if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber, size.uint64Value >= maximumBytes {
            if manager.fileExists(atPath: previousFileURL.path) { try manager.removeItem(at: previousFileURL) }
            try manager.moveItem(at: fileURL, to: previousFileURL)
            rotated = true
        }
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if rotated || event.event == .finished || event.event == .itemFinished {
            recentCache = nil
        }
    }

    func events(runID: UUID? = nil) throws -> [CleanupLogEvent] {
        lock.lock(); defer { lock.unlock() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var events: [CleanupLogEvent] = []
        for url in [directory.appending(path: "cleanup.previous.jsonl"), fileURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            events += try Data(contentsOf: url).split(separator: 0x0A).compactMap {
                try? decoder.decode(CleanupLogEvent.self, from: Data($0))
            }
        }
        return events.filter { runID == nil || $0.runID == runID }
    }
}
