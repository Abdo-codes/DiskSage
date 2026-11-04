import SwiftUI

struct CleanupHistoryView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cleanup history").font(.title2.weight(.semibold))
                    Text("Completed runs from the local cleanup log.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refreshDashboard)
            }
            .padding(18)
            Divider()
            List(model.recentActivity) { run in
                DisclosureGroup {
                    CleanupRunDetails(run: run)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(run.timestamp, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                                .font(.headline)
                            Spacer()
                            Text(run.trigger.title).foregroundStyle(.secondary)
                        }
                        HStack {
                            if run.hasWarnings { Image(systemName: "exclamationmark.triangle").accessibilityLabel("Cleanup warning") }
                            Text("\(run.succeededCount) removed · \(run.failedCount) failed")
                        }
                        .font(.callout)
                        Text(run.itemDescription).font(.callout).lineLimit(2)
                    }
                    .padding(.vertical, 6)
                }
            }
            .overlay {
                if model.recentActivity.isEmpty {
                    ContentUnavailableView("No completed cleanup", systemImage: "clock.arrow.circlepath",
                        description: Text(model.activityError ?? "Cleanup results will appear here after a run finishes."))
                }
            }
            Divider()
            HStack {
                Text("Size estimates and changes in available space are recorded separately.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open log folder", systemImage: "folder", action: model.openCleanupLogs)
            }
            .padding(14)
        }
    }
}

private struct CleanupRunDetails: View {
    let run: CleanupRunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Removed-item size estimate", value: run.estimatedRemovedBytes.diskSize)
            if let change = run.availableSpaceChange {
                LabeledContent("Available-space change at completion", value: change.diskSize)
                    .help("Other apps, shared files, and delayed filesystem reclamation can affect this measurement.")
            }
            if let error = run.error {
                Label(error, systemImage: "exclamationmark.triangle")
            }
            if run.failedCount > 0 {
                Text("Failed targets may have been partially removed before the error occurred.")
            }
            if run.items.isEmpty {
                Text("Individual item details are no longer in the retained log.").foregroundStyle(.secondary)
            } else {
                ForEach(run.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.succeeded == true ? "checkmark.circle" : "exclamationmark.triangle")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayName).fontWeight(.medium)
                            if let path = item.path { Text(path).textSelection(.enabled) }
                            if let error = item.message { Text(error) }
                        }
                        Spacer()
                        Text(item.succeeded == true ? "Removed" : "Failed")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .font(.callout).padding(.vertical, 10)
    }
}
