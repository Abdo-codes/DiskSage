import Foundation

enum ReviewRiskFilter: String, CaseIterable, Identifiable {
    case all, lowRisk, needsReview
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All risks"
        case .lowRisk: "Low risk"
        case .needsReview: "Needs review"
        }
    }
}

enum ReviewFilter {
    static func candidates(_ candidates: [CleanupCandidate], query: String, risk: ReviewRiskFilter) -> [CleanupCandidate] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter { candidate in
            let matchesRisk = risk == .all || (risk == .lowRisk ? candidate.risk == .low : candidate.risk != .low)
            return matchesRisk && (term.isEmpty || candidate.name.localizedCaseInsensitiveContains(term) || candidate.url.path.localizedCaseInsensitiveContains(term))
        }
    }

    static func mergeSelection(_ selection: Set<UUID>, visibleSelection: Set<UUID>, visibleIDs: Set<UUID>) -> Set<UUID> {
        selection.subtracting(visibleIDs).union(visibleSelection.intersection(visibleIDs))
    }
}
