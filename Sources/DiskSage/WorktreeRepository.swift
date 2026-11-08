import Foundation

/// One atomic, private document for approved scope and bounded idempotency records.
final class WorktreeRepository: @unchecked Sendable {
    static let standard = WorktreeRepository(url: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/DiskSage/worktrees.json"))
    struct Intent: Codable { var preview: WorktreePreview; var timestamp = Date() }
    struct Document: Codable {
        var configuration = WorktreeConfiguration()
        var receipts: [WorktreeReceipt] = []
        var intents: [Intent] = []
    }
    let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }
    func configuration() throws -> WorktreeConfiguration { try read().configuration }
    func receipt(_ id: UUID) throws -> WorktreeReceipt? { try read().receipts.first { $0.request.requestID == id } }
    func save(_ configuration: WorktreeConfiguration) throws { try update { $0.configuration = configuration } }
    func save(_ receipt: WorktreeReceipt) throws {
        try update {
            $0.receipts.removeAll { $0.request.requestID == receipt.request.requestID }
            $0.receipts.append(receipt)
            $0.receipts = Array($0.receipts.suffix(200))
        }
    }
    func intent(_ preview: WorktreePreview) throws {
        try update { $0.intents.append(Intent(preview: preview)); $0.intents = Array($0.intents.suffix(100)) }
    }
    private func read() throws -> Document { lock.lock(); defer { lock.unlock() }; return try load() }
    private func load() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) < 32_000_000 else {
            throw FeatureFailure(message: "Worktree settings/journal is symlinked or exceeds its safety limit.")
        }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    }
    private func update(_ change: (inout Document) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var document = try load(); change(&document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var data = try JSONEncoder().encode(document)
        while data.count >= 32_000_000 && document.intents.count > 1 {
            document.intents.removeFirst()
            data = try JSONEncoder().encode(document)
        }
        guard data.count < 32_000_000 else { throw FeatureFailure(message: "This approval exceeds the journal size limit. Review fewer checkouts in one batch.") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
}
