import SwiftUI

struct DeletionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let candidates: [CleanupCandidate]
    var trigger: CleanupTrigger = .manual
    var toolJobID: UUID? = nil
    init(id: UUID = UUID(), candidates: [CleanupCandidate], trigger: CleanupTrigger = .manual, toolJobID: UUID? = nil) {
        self.id = id
        self.candidates = candidates
        self.trigger = trigger
        self.toolJobID = toolJobID
    }
    var estimatedBytes: Int64 { candidates.reduce(0) { $0 + $1.size } }
}

struct DeletionConfirmationView: View {
    let request: DeletionRequest
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Permanently delete \(request.candidates.count) item(s)?", systemImage: "trash")
                .font(.title2.weight(.semibold))
            if request.trigger == .agent {
                Label("Requested by a connected agent", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            }
            Text("Estimated size: \(request.estimatedBytes.diskSize). These items will not go to the Trash and cannot be undone.")
            if request.candidates.contains(where: { $0.risk == .high }) {
                Label("Sensitive data is selected, such as archives or simulator data. Review every path before continuing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(candidate.name) · \(candidate.size.diskSize)").fontWeight(.medium)
                            Text(candidate.url.path).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(candidate.reason).font(.callout)
                            Label { Text(candidate.deletionScope) } icon: { Image(systemName: "trash") }
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Permanently Delete", role: .destructive, action: confirm)
                    .disabled(request.candidates.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
