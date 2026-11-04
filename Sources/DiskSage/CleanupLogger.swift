import Foundation

enum CleanupTrigger: String, Codable, Sendable {
    case manual
    case automatic
    case agent

    var title: String {
        switch self {
        case .manual: "Manual"
        case .automatic: "Automatic"
        case .agent: "Agent"
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

    let directory: URL
    var fileURL: URL { directory.appending(path: "cleanup.jsonl") }
    private let maximumBytes: UInt64
    private let lock = NSLock()

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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [CleanupLogEvent] = []
        for url in [directory.appending(path: "cleanup.previous.jsonl"), fileURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            events += data.split(separator: 0x0A).compactMap { line in
                try? decoder.decode(CleanupLogEvent.self, from: Data(line))
            }
        }
        return CleanupHistory.summaries(from: events, limit: limit)
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

        if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber, size.uint64Value >= maximumBytes {
            let previous = directory.appending(path: "cleanup.previous.jsonl")
            if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
            try manager.moveItem(at: fileURL, to: previous)
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
    }
}
