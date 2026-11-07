import CryptoKit
import Foundation

struct GitWorktree: Codable, Equatable, Sendable, Identifiable {
    var id: String { Self.digest(commonDirectory + "\0" + path) }
    var path: String
    var commonDirectory: String
    var branch: String?
    var head: String
    var locked: Bool
    var missing: Bool
    var main: Bool
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct WorktreeInspection: Codable, Equatable, Sendable, Identifiable {
    var id: String { worktree.id }
    var worktree: GitWorktree
    var inspectedAt = Date()
    var staged: [String] = []
    var modified: [String] = []
    var conflicted: [String] = []
    var untracked: [String] = []
    var ignored: [String] = []
    var ignoredFiles: [WorktreeIgnoredFile]? = nil
    var ignoredCountSummary: Int? = nil
    var ignoredBytesSummary: Int64? = nil
    var ignoredFileCount: Int { ignoredCountSummary ?? (ignoredFiles?.isEmpty == false ? ignoredFiles!.count : ignored.count) }
    var ignoredBytes: Int64 { ignoredBytesSummary ?? ignoredFiles?.reduce(0) { $0 + $1.estimatedBytes } ?? 0 }
    var hasIgnoredFiles: Bool { ignoredFileCount > 0 || !ignored.isEmpty }
    var blockers: [String] = []
    // Optional so existing journals remain readable. These risks require separate native approval.
    var removalWarnings: [String]? = nil
    var cleanupConcerns: [String]? = nil
    var retainedRefs: [String: String] = [:]
    var localCommits: [String] = []
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    var integrationRef: String?
    var integrationOID: String?
    var merged: Bool?
    var estimatedBytes: Int64 = 0
    var fingerprint = ""
    var activity = "Activity unknown; stop all work before removal."
    var discardReasons: [String] { removalWarnings ?? [] }
    var requiresDiscardApproval: Bool { !discardReasons.isEmpty }
    var canRequestRemoval: Bool { blockers.isEmpty && !fingerprint.isEmpty }
    var canRemove: Bool { canRequestRemoval && (!requiresDiscardApproval || isDisposable) }
    var isDisposable: Bool { canRequestRemoval && cleanupConcerns?.isEmpty == true }
    var label: String {
        if worktree.main { return "Primary checkout" }
        if worktree.missing { return "Missing checkout" }
        if worktree.locked { return "Locked" }
        if isDisposable { return "Disposable — branches kept" }
        if !staged.isEmpty || !modified.isEmpty || !conflicted.isEmpty || !untracked.isEmpty { return "Uncommitted files" }
        if blockers.contains(where: { $0.contains("recovery history") }) { return "Recovery commits to preserve" }
        if !blockers.isEmpty { return "Needs attention" }
        if requiresDiscardApproval { return "Destructive review required" }
        if hasIgnoredFiles { return "Review ignored files" }
        return merged == true ? "Ready for review" : "Not proven merged"
    }
}

struct WorktreePreview: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var items: [WorktreeInspection]
    var toolRequestID: UUID?
    var protectionChange: Bool? = nil
    var ignoredFilesApproved: Bool? = nil
    var quickReviewTotal: Int? = nil
    var discardChangesApproved: Bool? = nil
    var requiresIgnoredApproval: Bool { items.contains(where: \.hasIgnoredFiles) }
    var requiresDiscardApproval: Bool { items.contains(where: \.requiresDiscardApproval) }
    var requiresExtraAcknowledgement: Bool {
        items.contains { !$0.isDisposable && ($0.hasIgnoredFiles || $0.requiresDiscardApproval) }
    }
    var estimatedBytes: Int64 { items.reduce(0) { $0 + $1.estimatedBytes } }
}

struct WorktreeResult: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var path: String
    var succeeded: Bool
    var message: String
}

struct WorktreeConfiguration: Codable, Equatable, Sendable {
    var roots: [String] = []
    var protectedIDs: Set<String> = []
    var integrationRefs: [String: String] = [:]
}

struct WorktreeReceipt: Codable, Equatable, Sendable {
    var request: AgentToolRequest
    var timestamp = Date()
    var result: ToolValue
}
