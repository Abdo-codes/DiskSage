import Foundation

enum AgentCleanupPolicy: String, Sendable, CaseIterable, Identifiable {
    case disabled
    case confirm
    case automaticLowRisk

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .confirm: "Confirm in DiskSage"
        case .automaticLowRisk: "Allow low-risk cleanup"
        }
    }
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "agentCleanupPolicy") ?? "") ?? .confirm
    }
}

struct AgentToolRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case status, scan, cleanLowRisk, job, manage }
    let action: Action
    var requestID: UUID? = nil
    var tool: String? = nil
    var arguments: [String: ToolValue]? = nil
}

struct AgentToolStatus: Equatable, Codable, Sendable {
    let busy: Bool
    let awaitingConfirmation: Bool
    let freeSpaceBytes: Int64
    let candidateCount: Int
    let lowRiskCount: Int
    let lowRiskBytes: Int64
    let lastScanDate: Date?
    let cleanupPolicy: String
}

struct AgentToolJob: Equatable, Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case scanning, awaitingConfirmation, cleaning, advising, loading, succeeded, warnings, failed, cancelled
        var isTerminal: Bool { [.succeeded, .warnings, .failed, .cancelled].contains(self) }
    }
    let id: UUID
    let action: AgentToolRequest.Action
    let startedAt: Date
    var phase: Phase
    var completedAt: Date?
    var candidateCount = 0
    var estimatedBytes: Int64 = 0
    var removedEntryCount = 0
    var completedCount = 0
    var deletedCount = 0
    var failedCount = 0
    var estimatedRemovedBytes: Int64 = 0
    var actualRecoveredBytes: Int64 = 0
    var loggingFailed = false
    var result: ToolValue?
}

struct AgentToolReply: Equatable, Codable, Sendable {
    var status: AgentToolStatus? = nil
    var job: AgentToolJob? = nil
    var error: String? = nil
    var data: ToolValue? = nil
}
