import Foundation

struct CleanupSchedule: Codable, Equatable, Identifiable, Sendable {
    enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily, weekly, once
        var title: LocalizedStringResource {
            switch self { case .daily: "Daily"; case .weekly: "Weekly"; case .once: "Once" }
        }
    }
    enum Scope: String, Codable, CaseIterable, Sendable {
        case lowRisk, folderContents
        var title: LocalizedStringResource {
            switch self { case .lowRisk: "Low-risk generated files"; case .folderContents: "All folder contents" }
        }
    }

    var id = UUID()
    var folder: URL
    var folderIdentity: FileIdentity
    var scope: Scope = .lowRisk
    var frequency: Frequency = .daily
    var hour = 2
    var minute = 0
    var weekday = 1
    var oneTimeDate = Date().addingTimeInterval(3_600)
    var isEnabled = true
    var nextRun: Date?
    var lastRun: Date?
    var lastResult: String?
    var timeZoneIdentifier = TimeZone.current.identifier
    var revision: UInt64 = 0

    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute), (1...7).contains(weekday) else { return nil }
        if frequency == .once { return oneTimeDate > date ? oneTimeDate : nil }
        var components = DateComponents(hour: hour, minute: minute, second: 0)
        if frequency == .weekly { components.weekday = weekday }
        // A skipped DST time moves forward; a repeated time fires only once.
        return calendar.nextDate(after: date, matching: components,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    func hasSameAuthorization(as other: Self) -> Bool {
        id == other.id && folder.standardizedFileURL.path == other.folder.standardizedFileURL.path &&
            folderIdentity == other.folderIdentity && scope == other.scope
    }
}

struct ScheduledCleanupRun: Equatable, Sendable {
    var schedule: CleanupSchedule
    var operationID: UUID
}

struct CleanupScheduleRepository: Sendable {
    static let standard = Self(fileURL: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/DiskSage/schedules.json"))
    let fileURL: URL

    func load() throws -> [CleanupSchedule] {
        try document().schedules
    }

    func save(_ schedules: [CleanupSchedule]) throws {
        var stored = try document()
        stored.schedules = schedules
        try write(stored)
    }
    func receipts() throws -> [ToolMutationReceipt] { try document().receipts }
    func save(_ schedules: [CleanupSchedule], receipt: ToolMutationReceipt) throws {
        var stored = try document()
        guard !stored.receipts.contains(where: { $0.request.requestID == receipt.request.requestID }) else {
            throw FeatureFailure(message: "This request_id has already been applied. Read its result before retrying.")
        }
        stored.schedules = schedules
        stored.receipts.append(receipt)
        stored.receipts = Array(stored.receipts.suffix(200))
        try write(stored)
    }
    private struct Document: Codable {
        var version = 1
        var schedules: [CleanupSchedule] = []
        var receipts: [ToolMutationReceipt] = []
    }
    private func document() throws -> Document {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Document() }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let stored: Document
        if let legacy = try? decoder.decode([CleanupSchedule].self, from: data) { stored = Document(schedules: legacy) }
        else { stored = try decoder.decode(Document.self, from: data) }
        guard stored.version == 1, Set(stored.schedules.map(\.id)).count == stored.schedules.count,
              Set(stored.receipts.compactMap { $0.request.requestID }).count == stored.receipts.count else {
            throw FeatureFailure(message: "The schedule file has an unsupported version or duplicate identifiers.")
        }
        return stored
    }
    private func write(_ stored: Document) throws {
        guard Set(stored.schedules.map(\.id)).count == stored.schedules.count else {
            throw FeatureFailure(message: "Duplicate schedule identifiers are not allowed.")
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(stored).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
