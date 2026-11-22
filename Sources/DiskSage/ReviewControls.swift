import AppKit
import SwiftUI

struct ReviewHeader: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleanup Review").font(.title2.weight(.semibold))
                    Text(model.statusMessage).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isScanning || model.isAdvising {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: model.cancelCurrentOperation)
                } else {
                    Button("Scan Again", systemImage: "arrow.clockwise", action: model.scan).disabled(model.isBusy)
                }
                AgentReviewButton(model: model)
            }
            if let error = model.errorMessage, error != model.cleanupReport?.loggingError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            ForEach(model.scanWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if !model.recommendationSummary.isEmpty {
                Label(model.recommendationSummary, systemImage: "sparkles")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
            }
        }
        .padding(18)
    }
}

struct ReviewFilterBar: View {
    @Binding var query: String
    @Binding var risk: ReviewRiskFilter
    @Binding var category: ReviewCategoryFilter
    @Binding var sort: ReviewSortOrder
    let visibleCount: Int
    let visibleBytes: Int64
    let totalCount: Int
    let hasSelection: Bool
    let canSelectLowRisk: Bool
    let selectLowRisk: () -> Void
    let clearSelection: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search name, path, or category", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search cleanup candidates")
                    .frame(minWidth: 180)
                Picker("Category", selection: $category) {
                    ForEach(ReviewCategoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 124).accessibilityLabel("Filter by category")
                Picker("Risk", selection: $risk) {
                    ForEach(ReviewRiskFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 114).accessibilityLabel("Filter by risk")
                Picker("Sort", selection: $sort) {
                    ForEach(ReviewSortOrder.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 118).accessibilityLabel("Sort candidates")
            }
            HStack(spacing: 10) {
                Text(summaryLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Select Visible Low Risk", action: selectLowRisk).disabled(!canSelectLowRisk)
                    .help("Select only low-risk items in the current results. Hidden selections stay selected.")
                Button("Clear All", action: clearSelection).disabled(!hasSelection)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var summaryLabel: String {
        visibleCount > 0 ? "\(visibleCount) of \(totalCount) · \(visibleBytes.diskSize)" : "\(visibleCount) of \(totalCount)"
    }
}

struct ReviewFooter: View {
    let model: AppModel
    let hiddenCount: Int
    let confirmDeletion: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.selectedCandidates.count) selected · \(model.selectedBytes.diskSize)").fontWeight(.medium)
                if hiddenCount > 0 {
                    Text("\(hiddenCount) selected item(s) are hidden by the filters.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Sizes are estimates. Review before deleting.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Reveal", systemImage: "folder") {
                guard let candidate = model.selectedCandidates.first else { return }
                NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
            }
            .disabled(model.selectedCandidates.count != 1)
            Button("Delete Selected", systemImage: "trash", role: .destructive, action: confirmDeletion)
                .disabled(model.selectedCandidates.isEmpty || model.isBusy)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}
