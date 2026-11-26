import SwiftUI

struct ReviewSelectionInspector: View {
    let selectedCandidates: [CleanupCandidate]
    let recommendations: [UUID: AgentRecommendation]

    var body: some View {
        if !selectedCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if selectedCandidates.count == 1, let candidate = selectedCandidates.first {
                    HStack(spacing: 8) {
                        Text(candidate.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Label {
                            Text(candidate.deletionScope)
                        } icon: {
                            Image(systemName: "trash")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text(candidate.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    if let recommendation = recommendations[candidate.id] {
                        Label(
                            "Agent (\(recommendation.decision.rawValue.capitalized)): \(recommendation.rationale)",
                            systemImage: "sparkles"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    }
                } else {
                    let lowRiskCount = selectedCandidates.filter { $0.risk == .low }.count
                    let reviewCount = selectedCandidates.count - lowRiskCount
                    Text("Selected breakdown: \(lowRiskCount) low risk, \(reviewCount) needs review. Select one item to inspect its reason and deletion scope.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4))
        }
    }
}
