import Foundation

/// How recent writes mark build output as in use.
/// A build that runs now writes new files next to older outputs. Deleting the older
/// outputs breaks or restarts that build, so a recent write keeps the whole group.
enum GeneratedActivityScope: Sendable {
    /// Caches with no build in progress semantics: only each file's own age counts.
    case none
    /// One build folder: any recent write keeps the whole folder.
    case wholeRoot
    /// A shared root that holds one build folder per project, such as Xcode's
    /// DerivedData: a recent write keeps only that project's folder.
    case perChild

    static func of(_ root: URL, rule: GeneratedCleanupRule,
                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        guard rule == .buildArtifacts else { return .none }
        let root = CleanupPath.fileURL(root)
        let shared = GeneratedCleanupScope.fixedLocations(home: CleanupPath.fileURL(home))
            .contains { $0.0 == root && $0.2 == .buildArtifacts }
        return shared ? .perChild : .wholeRoot
    }

    /// The group an entry belongs to, given its path relative to the root.
    func group(_ parts: [String]) -> String? {
        switch self {
        case .none: nil
        case .wholeRoot: ""
        case .perChild: parts.first
        }
    }
}
