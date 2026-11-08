import SwiftUI

struct WorktreeRemovalProgressView: View {
    let count: Int
    let cancelling: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(cancelling ? "Finishing the current worktree…" : "Deleting worktrees in the background…")
                    .fontWeight(.medium)
                Text("\(count) folders in this cleanup. You can browse, switch sections, or close this window. New selections apply to your next cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(cancelling ? "Cancellation Requested" : "Cancel Remaining", action: cancel)
                .disabled(cancelling)
                .help("The current Git removal finishes. Worktrees still waiting will be skipped.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
        .accessibilityElement(children: .contain)
    }
}
