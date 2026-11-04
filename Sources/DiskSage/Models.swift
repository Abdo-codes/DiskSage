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

struct CleanupCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let category: CandidateCategory
    let size: Int64
    let risk: RiskLevel
    let reason: String

    init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        category: CandidateCategory,
        size: Int64,
        risk: RiskLevel,
        reason: String
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.category = category
        self.size = size
        self.risk = risk
        self.reason = reason
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

extension Int64 {
    var diskSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
