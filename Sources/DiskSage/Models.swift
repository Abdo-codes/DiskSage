import Foundation

enum CandidateCategory: String, Codable, CaseIterable, Sendable {
    case cache
    case build
    case archive
    case simulator

    var title: String {
        switch self {
        case .cache: "Cache"
        case .build: "Build"
        case .archive: "Archive"
        case .simulator: "Simulator"
        }
    }

    var systemImage: String {
        switch self {
        case .cache: "shippingbox"
        case .build: "hammer"
        case .archive: "archivebox"
        case .simulator: "iphone"
        }
    }
}

enum RiskLevel: Int, Codable, Comparable, Sendable {
    case low
    case medium
    case high

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .low: "Low risk"
        case .medium: "Review"
        case .high: "Sensitive"
        }
    }
}

enum DeletionMode: String, Codable, Sendable {
    case item
    case contents
    case simulatorDevices
}

struct FileIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct CleanupCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let category: CandidateCategory
    let size: Int64
    let risk: RiskLevel
    let reason: String
    let identity: FileIdentity
    let deletionMode: DeletionMode

    init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        category: CandidateCategory,
        size: Int64,
        risk: RiskLevel,
        reason: String,
        identity: FileIdentity = FileIdentity(device: 0, inode: 0),
        deletionMode: DeletionMode = .item
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.category = category
        self.size = size
        self.risk = risk
        self.reason = reason
        self.identity = identity
        self.deletionMode = deletionMode
    }
}

struct AgentRecommendation: Codable, Sendable {
    enum Decision: String, Codable, Sendable {
        case delete
        case keep
        case review
    }

    let id: UUID
    let decision: Decision
    let rationale: String
}

struct AgentResponse: Codable, Sendable {
    let summary: String
    let recommendations: [AgentRecommendation]
}

struct CleanupItemResult: Sendable {
    let candidate: CleanupCandidate
    let removedBytes: Int64
    let errorDescription: String?

    var succeeded: Bool { errorDescription == nil }
}

struct CleanupReport: Sendable {
    let items: [CleanupItemResult]
    let freeSpaceBefore: Int64
    let freeSpaceAfter: Int64

    var estimatedRemovedBytes: Int64 {
        items.filter(\.succeeded).reduce(0) { $0 + $1.removedBytes }
    }

    var actualRecoveredBytes: Int64 {
        max(0, freeSpaceAfter - freeSpaceBefore)
    }

    var failures: [CleanupItemResult] { items.filter { !$0.succeeded } }
}

extension Int64 {
    var diskSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
