import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    var heightLimit: CGFloat?
    let openReview: () -> Void
    let openSettings: () -> Void
    let openHistory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(status: model.pendingDeletionRequest != nil ? String(localized: "Confirmation required") : model.statusMessage,
                            working: model.dashboardPresentation.isWorking, canScan: !model.isBusy,
                            rescan: model.scan, openSettings: openSettings)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            if let heightLimit {
                ScrollView { DashboardContent(model: model, openReview: openReview, openHistory: openHistory) }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: heightLimit)
            } else {
                DashboardContent(model: model, openReview: openReview, openHistory: openHistory)
            }
            DashboardFooter(canQuit: !model.isCleaning, openLogs: model.openCleanupLogs)
        }
        .frame(width: 368, height: heightLimit)
        .fixedSize(horizontal: false, vertical: heightLimit == nil)
        .foregroundStyle(.primary)
    }
}

private struct DashboardContent: View {
    let model: AppModel
    let openReview: () -> Void
    let openHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiskUsageCard(usage: model.diskUsage)
            Divider()
            CleanupOverviewCard(breakdown: CleanupBreakdown(candidates: model.candidates),
                                count: model.candidates.count, scanning: model.isScanning, hasScanned: model.lastScanDate != nil)
            DashboardActions(model: model, openReview: openReview)
            if let error = model.errorMessage {
                DashboardWarning(message: "\(error)", maximumLines: 3)
            }
            Divider()
            DashboardActivityView(events: model.recentActivity, error: model.activityError, openHistory: openHistory)
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }
}

private struct DashboardActions: View {
    let model: AppModel
    let openReview: () -> Void

    var body: some View {
        let presentation = model.dashboardPresentation
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if presentation.primaryAction == .scan { model.scan() } else { openReview() }
            } label: {
                HStack {
                    Text(presentation.primaryTitle)
                    Spacer()
                    Image(systemName: presentation.primaryAction == .scan ? "arrow.clockwise" : "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .modifier(DashboardActionStyle(prominent: true)).controlSize(.large)
            Button {
                openReview()
                model.requestLowRiskCleanup()
            } label: {
                Label("Clean Low-Risk Items…", systemImage: "sparkles.rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .modifier(DashboardActionStyle()).controlSize(.large)
            .disabled(!presentation.canCleanNow)
            .help("Review and confirm low-risk cleanup now, regardless of the low-disk threshold.")
            if model.isScanning || model.isAdvising {
                Button("Cancel", action: model.cancelCurrentOperation)
                    .buttonStyle(.borderless).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                AgentReviewButton(model: model, compact: true)
            }
        }
    }
}

private struct DashboardHeader: View {
    let status: String
    let working: Bool
    let canScan: Bool
    let rescan: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive.badge.checkmark").font(.title2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("DiskSage").font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(status)
            }
            Spacer(minLength: 4)
            if working {
                ProgressView().controlSize(.small).accessibilityLabel(status)
            } else {
                Button(action: rescan) { Image(systemName: "arrow.clockwise") }
                    .disabled(!canScan).help("Scan again").accessibilityLabel("Scan again")
            }
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .help("Settings").accessibilityLabel("Settings")
        }
        .buttonStyle(.borderless).controlSize(.small)
    }
}

private struct DashboardFooter: View {
    let canQuit: Bool
    let openLogs: () -> Void
    @AppStorage("automaticCleanupEnabled") private var automaticCleanupEnabled = true
    @AppStorage("cleanupThresholdGiB") private var cleanupThresholdGiB = 15

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: automaticCleanupEnabled ? "checkmark.shield" : "pause.circle")
                .accessibilityHidden(true)
            if automaticCleanupEnabled {
                Text("Low-disk auto below \(cleanupThresholdGiB) GiB")
            } else {
                Text("Low-disk cleanup off")
            }
            Spacer()
            Button(action: openLogs) { Image(systemName: "doc.text.magnifyingglass") }
                .help("Open log folder").accessibilityLabel("Open log folder")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .disabled(!canQuit).help(canQuit ? "Quit DiskSage" : "Wait for cleanup to finish before quitting")
        }
        .buttonStyle(.borderless).font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(alignment: .top) { Divider() }
    }
}
