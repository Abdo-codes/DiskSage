import SwiftUI

extension CleanupCandidate {
    var deletionScope: LocalizedStringResource {
        switch deletionMode {
        case .item: "Deletes this item and everything inside it."
        case .contents: "Deletes the contents; keeps the parent folder."
        case .generatedFiles: "Deletes only verified generated files from this scan. Source, test evidence, installed tool bundles, and the parent folder stay."
        case .simulatorDevices: "Refused: DiskSage deletes simulators one device at a time."
        case .simulatorDevice: "Deletes this one simulator device with simctl, including its installed apps and their data."
        }
    }
}

struct CandidateRiskView: View {
    let candidate: CleanupCandidate
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 5) {
            Text(candidate.risk.title)
            Button { showsDetails = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Risk and deletion details for \(candidate.name)")
                .help(candidate.reason)
                .popover(isPresented: $showsDetails) {
                    CandidateDetailsView(candidate: candidate)
                }
        }
    }
}

private struct CandidateDetailsView: View {
    let candidate: CleanupCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(candidate.name).font(.headline)
            LabeledContent("Risk", value: candidate.risk.title)
            Text(candidate.reason)
            Label { Text(candidate.deletionScope) } icon: { Image(systemName: "trash") }
                .font(.callout)
            Text(candidate.url.path).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
