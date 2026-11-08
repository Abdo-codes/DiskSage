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
    let visibleCount: Int
    let totalCount: Int
    let hasSelection: Bool
    let canSelectLowRisk: Bool
    let selectLowRisk: () -> Void
    let clearSelection: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Search name or path", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search cleanup candidates")
                .frame(minWidth: 180)
            Picker("Risk", selection: $risk) {
                ForEach(ReviewRiskFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 125).accessibilityLabel("Filter by risk")
            Text("\(visibleCount) of \(totalCount)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("Select Visible Low Risk", action: selectLowRisk).disabled(!canSelectLowRisk)
                .help("Select only low-risk items in the current results. Hidden selections stay selected.")
            Button("Clear All", action: clearSelection).disabled(!hasSelection)
        }
        .controlSize(.small)
        .padding(.horizontal, 18).padding(.vertical, 10)
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
