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

enum ReviewCategoryFilter: String, CaseIterable, Identifiable {
    case all, build, cache, simulator, archive
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All categories"
        case .build: "Builds"
        case .cache: "Caches"
        case .simulator: "Simulators"
        case .archive: "Archives"
        }
    }

    func matches(_ category: CandidateCategory) -> Bool {
        switch self {
        case .all: true
        case .build: category == .build
        case .cache: category == .cache
        case .simulator: category == .simulator
        case .archive: category == .archive
        }
    }
}

enum ReviewSortOrder: String, CaseIterable, Identifiable {
    case largest, name, risk
    var id: Self { self }
    var title: String {
        switch self {
        case .largest: "Largest first"
        case .name: "Name"
        case .risk: "Lowest risk"
        }
    }
}

enum ReviewFilter {
    static func candidates(_ candidates: [CleanupCandidate], query: String, risk: ReviewRiskFilter,
                           category: ReviewCategoryFilter = .all, sort: ReviewSortOrder = .largest) -> [CleanupCandidate] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = candidates.filter { candidate in
            let matchesRisk = risk == .all || (risk == .lowRisk ? candidate.risk == .low : candidate.risk != .low)
            guard matchesRisk, category.matches(candidate.category) else { return false }
            guard !term.isEmpty else { return true }
            return candidate.name.localizedCaseInsensitiveContains(term)
                || candidate.url.path.localizedCaseInsensitiveContains(term)
                || candidate.category.title.localizedCaseInsensitiveContains(term)
        }
        switch sort {
        case .largest:
            return filtered.sorted {
                if $0.size != $1.size { return $0.size > $1.size }
                return tieBreak($0, $1)
            }
        case .name:
            return filtered.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                if order != .orderedSame { return order == .orderedAscending }
                return tieBreak($0, $1)
            }
        case .risk:
            return filtered.sorted {
                if $0.risk != $1.risk { return $0.risk < $1.risk }
                if $0.size != $1.size { return $0.size > $1.size }
                return tieBreak($0, $1)
            }
        }
    }

    private static func tieBreak(_ lhs: CleanupCandidate, _ rhs: CleanupCandidate) -> Bool {
        if lhs.url.path != rhs.url.path { return lhs.url.path < rhs.url.path }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func mergeSelection(_ selection: Set<UUID>, visibleSelection: Set<UUID>, visibleIDs: Set<UUID>) -> Set<UUID> {
        selection.subtracting(visibleIDs).union(visibleSelection.intersection(visibleIDs))
    }
}
