import AppKit
import SwiftUI

struct CacheReviewView: View {
    @Bindable var model: AppModel
    @Binding var query: String
    @Binding var riskFilter: ReviewRiskFilter
    @Binding var categoryFilter: ReviewCategoryFilter
    @Binding var sortOrder: ReviewSortOrder
    @State private var visibleCandidates: [CleanupCandidate] = []

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(model: model)
            ReviewFilterBar(query: $query, risk: $riskFilter, category: $categoryFilter, sort: $sortOrder,
                visibleCount: visibleCandidates.count,
                visibleBytes: visibleCandidates.reduce(0) { $0 + $1.size },
                totalCount: model.candidates.count, hasSelection: !model.selection.isEmpty,
                canSelectLowRisk: visibleCandidates.contains { $0.risk == .low },
                selectLowRisk: {
                    model.selection = ReviewFilter.mergeSelection(model.selection,
                        visibleSelection: Set(visibleCandidates.filter { $0.risk == .low }.map(\.id)), visibleIDs: visibleIDs)
                },
                clearSelection: { model.selection = [] })
            Divider()
            if model.isCleaningCaches || model.worktrees.removing || model.cleanupReport != nil {
                CleanupFeedbackView(model: model)
                Divider()
            }
            candidateTable
            if !model.selectedCandidates.isEmpty {
                Divider()
                ReviewSelectionInspector(selectedCandidates: model.selectedCandidates,
                                         recommendations: model.recommendations)
            }
            Divider()
            ReviewFooter(model: model, hiddenCount: model.selection.subtracting(visibleIDs).count) {
                model.requestDeletion(model.selectedCandidates)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.candidates, initial: true) { _, _ in updateVisibleCandidates() }
        .onChange(of: query) { _, _ in updateVisibleCandidates() }
        .onChange(of: riskFilter) { _, _ in updateVisibleCandidates() }
        .onChange(of: categoryFilter) { _, _ in updateVisibleCandidates() }
        .onChange(of: sortOrder) { _, _ in updateVisibleCandidates() }
    }

    private var candidateTable: some View {
        Table(visibleCandidates, selection: visibleSelection) {
            TableColumn("Item") { candidate in
                HStack {
                    Image(systemName: candidate.category.systemImage)
                        .foregroundStyle(color(for: candidate.risk))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(candidate.name)
                        if let failure = model.cleanupFailures.first(where: { $0.candidate.id == candidate.id }) {
                            Label(failure.errorDescription ?? "Could not delete", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                                .help(failure.errorDescription ?? "Could not delete")
                        }
                        Text(candidate.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(candidate.reason)
            }
            .width(min: 280, ideal: 420)

            TableColumn("Size") { candidate in
                Text(candidate.size.diskSize)
                    .monospacedDigit()
            }
            .width(80)

            TableColumn("Risk") { candidate in
                CandidateRiskView(candidate: candidate)
            }
            .width(110)

            TableColumn("Agent") { candidate in
                if let recommendation = model.recommendations[candidate.id] {
                    Text(recommendation.decision.rawValue.capitalized)
                        .help(recommendation.rationale)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UUID.self) { ids in
            let items = visibleCandidates.filter { ids.contains($0.id) }
            if items.count == 1, let item = items.first {
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            }
            if !items.isEmpty {
                Button(items.count == 1 ? "Copy Path" : "Copy Paths", systemImage: "doc.on.doc") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(items.map(\.url.path).joined(separator: "\n"), forType: .string)
                }
                Divider()
                Button(items.count == 1 ? "Keep (Exclude from Scans)" : "Keep \(items.count) Items (Exclude from Scans)",
                       systemImage: "pin.slash") {
                    model.keepCandidates(items)
                }
                .disabled(model.isBusy)
            }
        }
        .overlay {
            if visibleCandidates.isEmpty {
                ContentUnavailableView(
                    model.isScanning ? "Scanning…" : (model.isCleaningCaches ? "Finishing cleanup…" : (model.candidates.isEmpty ? "No Candidates" : "No Matches")),
                    systemImage: model.isScanning ? "externaldrive" : "magnifyingglass",
                    description: Text(model.isScanning ? "Finding generated files and caches." : (model.isCleaningCaches ? "Completed items are removed as cleanup progresses." : "Try changing the search or risk filter, or run a new scan."))
                )
            }
        }
    }

    private var visibleIDs: Set<UUID> { Set(visibleCandidates.map(\.id)) }

    private var visibleSelection: Binding<Set<UUID>> {
        Binding(get: { model.selection.intersection(visibleIDs) }, set: { selected in
            model.selection = ReviewFilter.mergeSelection(model.selection, visibleSelection: selected, visibleIDs: visibleIDs)
        })
    }

    private func updateVisibleCandidates() {
        visibleCandidates = ReviewFilter.candidates(model.candidates, query: query, risk: riskFilter,
                                                    category: categoryFilter, sort: sortOrder)
    }

    private func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

}
