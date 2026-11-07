import Foundation

struct WorktreeIgnoredFile: Codable, Equatable, Sendable, Identifiable {
    var id: String { path }
    var path: String
    var estimatedBytes: Int64
    var symbolicLink: Bool
}

enum WorktreeIgnoredFiles {
    static func paths(git: WorktreeGitProcess, checkout: String) throws -> Set<String> {
        let data = try git.run(checkout, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]).data
        guard let text = String(data: data, encoding: .utf8) else {
            throw FeatureFailure(message: "Ignored file names are not valid UTF-8; inspection is incomplete.")
        }
        let paths = text.split(separator: "\0").map(String.init)
        guard paths.count <= 150_000, paths.allSatisfy({ path in
            !path.hasPrefix("/") && !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        }) else { throw FeatureFailure(message: "Ignored file inventory exceeded its safety limit or contains an unsafe path.") }
        return Set(paths)
    }
}

enum WorktreeQuickCleanup {
    static let batchLimit = 300
    static func compactForReview(_ item: WorktreeInspection) -> WorktreeInspection {
        guard item.isDisposable else { return item }
        var result = item
        result.ignoredCountSummary = item.ignoredFileCount
        result.ignoredBytesSummary = item.ignoredBytes
        result.ignoredFiles = nil
        result.ignored = Set(item.ignored.compactMap { $0.split(separator: "/").first.map(String.init) })
            .sorted().map { $0 == ".DS_Store" ? $0 : $0 + "/" }
        // Keep the original fingerprint: execution re-inspects every file, including cache contents.
        return result
    }
    static func validateSize(_ items: [WorktreeInspection]) throws {
        guard try JSONEncoder().encode(items).count < 16_000_000 else {
            throw FeatureFailure(message: "This review exceeds the size limit. Select fewer checkouts per batch.")
        }
    }
    static func candidates(_ items: [WorktreeInspection]) -> [WorktreeInspection] {
        items.filter(\.isDisposable)
    }
    static func preview(_ items: [WorktreeInspection], id: UUID) throws -> WorktreePreview {
        let candidates = candidates(items)
        guard !candidates.isEmpty else {
            throw FeatureFailure(message: "No checkouts currently pass the review checks. Inspect the reasons in the list, or add folders and refresh.")
        }
        var batch: [WorktreeInspection] = [], bytes = 0
        for original in candidates.prefix(batchLimit) {
            let candidate = compactForReview(original)
            let size = try JSONEncoder().encode(candidate).count
            guard size < 16_000_000 else { throw FeatureFailure(message: "This checkout needs individual review because its file inventory is too large.") }
            if !batch.isEmpty && bytes + size > 16_000_000 { break }
            batch.append(candidate); bytes += size
        }
        return WorktreePreview(id: id, items: batch, quickReviewTotal: candidates.count)
    }
}
