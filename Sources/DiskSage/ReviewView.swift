import AppKit
import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var riskFilter: ReviewRiskFilter = .all
    @State private var visibleCandidates: [CleanupCandidate] = []

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(model: model)
            ReviewFilterBar(query: $query, risk: $riskFilter, visibleCount: visibleCandidates.count,
                totalCount: model.candidates.count, busy: model.isBusy, hasSelection: !model.selection.isEmpty,
                canSelectLowRisk: visibleCandidates.contains { $0.risk == .low },
                selectLowRisk: {
                    model.selection = ReviewFilter.mergeSelection(model.selection,
                        visibleSelection: Set(visibleCandidates.filter { $0.risk == .low }.map(\.id)), visibleIDs: visibleIDs)
                },
                clearSelection: { model.selection = [] })
            Divider()
            if model.isCleaning || model.cleanupReport != nil {
                CleanupFeedbackView(model: model)
                Divider()
            }
            candidateTable
            Divider()
            ReviewFooter(model: model, hiddenCount: model.selection.subtracting(visibleIDs).count) {
                model.requestDeletion(model.selectedCandidates)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .onChange(of: model.candidates, initial: true) { _, _ in updateVisibleCandidates() }
        .onChange(of: query) { _, _ in updateVisibleCandidates() }
        .onChange(of: riskFilter) { _, _ in updateVisibleCandidates() }
        .sheet(item: Binding(get: { model.pendingDeletionRequest }, set: { value in
            if value == nil { model.cancelDeletionRequest() }
        })) { request in
            DeletionConfirmationView(request: request) {
                model.confirmDeletion(request)
            }
        }
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
        .overlay {
            if visibleCandidates.isEmpty {
                ContentUnavailableView(
                    model.isScanning ? "Scanning…" : (model.isCleaning ? "Finishing cleanup…" : (model.candidates.isEmpty ? "No Candidates" : "No Matches")),
                    systemImage: model.isScanning ? "externaldrive" : "magnifyingglass",
                    description: Text(model.isScanning ? "Finding generated files and caches." : (model.isCleaning ? "Completed items are removed as cleanup progresses." : "Try changing the search or risk filter, or run a new scan."))
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
        visibleCandidates = ReviewFilter.candidates(model.candidates, query: query, risk: riskFilter)
    }

    private func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

}
