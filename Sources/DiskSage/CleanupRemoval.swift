import Foundation

/// What a remover really removed when it differs from the scan. Files that changed after the scan stay, and this is not a failure.
struct CleanupRemoval: Equatable, Sendable {
    let removedBytes: Int64
    let skippedFiles: Int

    var note: String? {
        switch skippedFiles {
        case 0: nil
        case 1: "Kept 1 file that changed after the scan."
        default: "Kept \(skippedFiles) files that changed after the scan."
        }
    }
}
