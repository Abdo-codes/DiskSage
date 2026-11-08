import Foundation

enum WorktreeObjectPolicy {
    /// Checkout removal must never erase storage backing a retained shared reference.
    static func validate(common: String, checkout: String) throws {
        guard !WorktreePathGuard.contains(checkout, common) else {
            throw FeatureFailure(message: "Shared Git data is inside this checkout; removal is unsupported.")
        }
        try validateShared(common: common)
    }
    static func validateShared(common: String) throws {
        let objects = URL(fileURLWithPath: common + "/objects")
        _ = try WorktreePathGuard.identity(objects.path)
        let manager = FileManager.default
        for suffix in ["/objects/info/alternates", "/info/grafts"] where manager.fileExists(atPath: common + suffix) {
            throw FeatureFailure(message: "Borrowed Git objects or grafted history require external preservation review.")
        }
        var failed = false, count = 0
        guard let walker = manager.enumerator(at: objects, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, _ in failed = true; return false }) else {
            throw FeatureFailure(message: "Cannot verify shared Git object storage.")
        }
        for case let url as URL in walker {
            count += 1
            guard count <= 50_000, !Task.isCancelled else {
                throw FeatureFailure(message: "Shared Git object inspection exceeded its safety limit.")
            }
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw FeatureFailure(message: "Symlinked Git objects require external preservation review.")
            }
        }
        guard !failed else { throw FeatureFailure(message: "Shared Git objects could not be fully inspected.") }
    }
}
