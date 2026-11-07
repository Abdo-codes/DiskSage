import Foundation

enum WorktreeValuePolicy {
    static func isGenerated(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let first = parts.first, !path.hasPrefix("/"), !parts.contains("..") else { return false }
        return [".build", ".build-dd", "build", "DerivedData", "derived-data", ".cache"].contains(String(first)) ||
            path == ".DS_Store"
    }

    static func concerns(_ item: WorktreeInspection, ignored: Set<String>, metadataDisposable: Bool, retained: Bool, draft: Bool) -> [String] {
        var result: [String] = []
        if !item.staged.isEmpty || !item.modified.isEmpty || !item.conflicted.isEmpty { result.append("Unsaved source changes will be lost.") }
        if item.untracked.contains(where: { !isGenerated($0) }) { result.append("Untracked files outside generated caches will be lost.") }
        if ignored.contains(where: { !isGenerated($0) }) { result.append("Local settings or ignored files outside generated caches will be lost.") }
        if !metadataDisposable || draft { result.append("Private Git data or a draft commit message needs review.") }
        if !retained { result.append("Some commits or recovery history have no retained branch or tag.") }
        return result
    }
}
