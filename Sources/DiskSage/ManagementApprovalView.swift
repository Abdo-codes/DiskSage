import SwiftUI

struct ManagementApprovalView: View {
    let request: ManagementApproval
    let approve: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(request.title, systemImage: "hand.raised")
                .font(.title2.weight(.semibold))
            Label("Requested by a connected agent", systemImage: "sparkles")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(request.details).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Decline", role: .cancel, action: reject).keyboardShortcut(.cancelAction)
                Button("Approve change", action: approve).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
    }
}
