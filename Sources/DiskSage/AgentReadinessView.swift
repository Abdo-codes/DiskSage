import AppKit
import SwiftUI

struct AgentReadinessView: View {
    let readiness: AgentReadiness?
    let provider: AgentProvider

    var body: some View {
        switch readiness {
        case .none:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking \(provider.title)…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .ready:
            Label(provider == .claude || provider == .codex ? "CLI found · uses your existing sign-in" : "Ready for metadata review",
                  systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case let .unavailable(reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up Agent…") {
                    NSApp.sendAction(#selector(DiskSageAppDelegate.showAgentSettings), to: nil, from: nil)
                }
                .buttonStyle(.link).font(.caption)
            }
            .frame(maxWidth: 340, alignment: .leading)
        }
    }
}
