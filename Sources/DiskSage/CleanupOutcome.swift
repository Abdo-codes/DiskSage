import Foundation

struct CleanupOutcome {
    let report: CleanupReport
    var hasWarnings: Bool { !report.failures.isEmpty || report.loggingError != nil }
    var title: String {
        let removed = report.items.filter(\.succeeded).count
        if report.loggingError != nil { return "Cleanup stopped; see details below" }
        if !report.failures.isEmpty { return "Cleanup finished: \(removed) deleted, \(report.failures.count) failed" }
        return "Deleted \(removed) item(s) · \(report.estimatedRemovedBytes.diskSize) estimated"
    }
}
