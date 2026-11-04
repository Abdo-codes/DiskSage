import SwiftUI

struct DiskUsageCard: View {
    let usage: DiskUsageSnapshot?

    var body: some View {
        HStack(spacing: 16) {
            if let usage {
                DiskUsageRing(usage: usage)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(usage.availableBytes.diskSize) available").font(.title3.weight(.semibold))
                    Text("\(usage.name) · \(usage.totalBytes.diskSize) capacity")
                        .font(.callout).lineLimit(2)
                }
            } else {
                Label("Disk capacity is unavailable", systemImage: "externaldrive.badge.questionmark")
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 76)
    }
}

private struct DiskUsageRing: View {
    let usage: DiskUsageSnapshot

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor, lineWidth: 8)
            Circle().trim(from: usage.usedFraction, to: 1)
                .stroke(Color.green, lineWidth: 8).rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(usage.usedFraction, format: .percent.precision(.fractionLength(0)))
                    .font(.headline)
                Text("used").font(.caption).foregroundStyle(DashboardTheme.muted)
            }
        }
        .frame(width: 64, height: 64).padding(5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk space used")
        .accessibilityValue(usage.usedFraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

struct CleanupOverviewCard: View {
    let breakdown: CleanupBreakdown
    let count: Int
    let scanning: Bool
    var hasScanned = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if scanning && count > 0 { Text("Previous scan estimates") } else { Text("Cleanup estimates") }
                }.font(.subheadline.weight(.semibold))
                Spacer()
                Group {
                    if scanning { Text("Scanning…") }
                    else if hasScanned { Text("\(count) items") }
                    else { Text("Not scanned yet") }
                }.font(.callout).foregroundStyle(DashboardTheme.muted)
            }
            HStack(spacing: 18) {
                RiskEstimate(label: "Low risk", bytes: breakdown.lowRiskBytes,
                             symbol: "checkmark.shield", color: .green, hasResults: count > 0)
                RiskEstimate(label: "Needs careful review", bytes: breakdown.reviewBytes,
                             symbol: "hand.raised", color: .orange, hasResults: count > 0)
            }
            CategoryBar(categories: breakdown.categories, totalBytes: breakdown.totalBytes)
            if count > 0 {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(breakdown.categories) { item in
                        HStack(spacing: 4) {
                            Circle().fill(DashboardTheme.color(for: item.category)).frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                            Text(item.category.title)
                            Spacer(minLength: 0)
                            Text(item.bytes.diskSize).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.callout)
                Text("Sizes are estimates.").font(.caption).foregroundStyle(DashboardTheme.muted)
            } else {
                Group {
                    if scanning { Text("Finding caches and generated files…") }
                    else if hasScanned { Text("No cleanup candidates in the last scan.") }
                    else { Text("Scan to find generated files and caches.") }
                }.font(.callout).foregroundStyle(DashboardTheme.muted)
            }
        }
    }
}

private struct RiskEstimate: View {
    let label: String
    let bytes: Int64
    let symbol: String
    let color: Color
    let hasResults: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(label).foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .font(.callout)
            Text(hasResults ? bytes.diskSize : "—").font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct CategoryBar: View {
    let categories: [CleanupBreakdown.Category]
    let totalBytes: Int64

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(categories) { item in
                    Rectangle().fill(DashboardTheme.color(for: item.category))
                        .frame(width: geometry.size.width * CGFloat(item.bytes) / CGFloat(max(1, totalBytes)))
                }
            }
            .background(.quaternary).clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
