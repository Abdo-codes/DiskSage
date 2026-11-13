import Foundation

/// The result of a scan that ran. `warnings` name the places that the scan could not check
/// completely, for example a folder above a safety limit. A warning never adds a candidate.
struct ScanReport: Equatable, Sendable {
    var candidates: [CleanupCandidate]
    var warnings: [String] = []
}
