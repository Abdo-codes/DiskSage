import SwiftUI

struct DashboardActivityView: View {
    let events: [CleanupRunSummary]
    let error: String?
    let openHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Last cleanup").font(.subheadline.weight(.semibold))
                if let event = events.first {
                    Text(event.timestamp, format: .dateTime.hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                        .help(event.timestamp.formatted(date: .complete, time: .shortened))
                }
                Spacer()
                Button("History", action: openHistory).buttonStyle(.borderless).font(.callout)
            }
            if let error {
                DashboardWarning(message: "History unavailable: \(error)")
            } else if let event = events.first {
                Text(event.succeededCount > 0 ? "\(event.succeededCount) removed · \(event.itemDescription)" : event.itemDescription)
                    .font(.callout).lineLimit(2)
                    .help(event.itemNames.joined(separator: "\n"))
                if let error = event.error {
                    DashboardWarning(message: "\(error)")
                } else if event.failedCount > 0 {
                    DashboardWarning(message: "\(event.failedCount) failed; partial removal is possible.")
                }
            } else {
                Text("No completed cleanup yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// An opaque semantic backing keeps small warning text readable over changing glass backgrounds.
struct DashboardWarning: View {
    let message: LocalizedStringResource
    var maximumLines = 2

    var body: some View {
        Label {
            Text(message).foregroundStyle(Color(nsColor: .labelColor))
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        .font(.callout).lineLimit(maximumLines)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .help(Text(message))
        .accessibilityElement(children: .combine)
    }
}
