import AppKit
import SwiftUI

struct CleanupFeedbackView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isCleaning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Deleting… \(model.cleanupCompletedCount) of \(model.cleanupTotalCount) folders completed")
                        .fontWeight(.medium)
                    Spacer()
                }
                ProgressView(value: Double(model.cleanupCompletedCount), total: Double(max(1, model.cleanupTotalCount)))
                Text("\(model.cleanupRemovedEntryCount.formatted()) files and folders removed · \(model.cleanupActiveItems.count) folders active")
                    .monospacedDigit().foregroundStyle(.secondary)
                Text(model.cleanupCurrentItem).foregroundStyle(.secondary).lineLimit(1)
            } else if let report = model.cleanupReport {
                let outcome = CleanupOutcome(report: report)
                Label(outcome.title, systemImage: outcome.hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .fontWeight(.medium)
                    .foregroundStyle(outcome.hasWarnings ? .orange : .green)
                if report.removedEntryCount > 0 {
                    Text("\(report.removedEntryCount.formatted()) files and folders removed").foregroundStyle(.secondary)
                }
                if !report.failures.isEmpty {
                    Text("Failed items remain in the list with their error. Some files inside them may already have been removed.")
                        .foregroundStyle(.secondary)
                }
                if let error = report.loggingError { Text(error).foregroundStyle(.red) }
                HStack {
                    Text("Available space immediately after cleanup: \(report.freeSpaceAfter.diskSize).")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("This is the completion snapshot. The dashboard shows current available space.")
                    Spacer()
                    Button("Open History") { showHistory() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.35))
        .accessibilityElement(children: .contain)
    }

    private func showHistory() {
        // Use the existing app command so history is always in the same window.
        NSApp.sendAction(#selector(DiskSageAppDelegate.showHistory), to: NSApp.delegate, from: nil)
    }
}
