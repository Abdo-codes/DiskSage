import AppKit
import ComposableArchitecture
import Testing
@testable import DiskSage

@MainActor
struct DashboardPresentationTests {
    @Test func emptyAndNoLowRiskStatesOfferUsefulActions() {
        let initial = DashboardPresentation(operation: .idle, hasScanned: false, candidateCount: 0,
                                            lowRiskCount: 0, awaitingConfirmation: false)
        #expect(initial.primaryAction == .scan && initial.canCleanNow)
        let empty = DashboardPresentation(operation: .idle, hasScanned: true, candidateCount: 0,
                                          lowRiskCount: 0, awaitingConfirmation: false)
        #expect(empty.primaryAction == .scan && !empty.canCleanNow)
        let sensitiveOnly = DashboardPresentation(operation: .idle, hasScanned: true, candidateCount: 5,
                                                  lowRiskCount: 0, awaitingConfirmation: false)
        #expect(sensitiveOnly.primaryAction == .review && !sensitiveOnly.canCleanNow)
        let eligible = DashboardPresentation(operation: .idle, hasScanned: true, candidateCount: 5,
                                             lowRiskCount: 2, awaitingConfirmation: false)
        #expect(eligible.primaryAction == .review && eligible.canCleanNow)
    }

    @Test(arguments: [AppOperation.scanning, .automaticScan, .advising, .cleaning, .automaticCleanup])
    func busyStatesShowTheRelevantProgressAndDisableNewCleanup(operation: AppOperation) {
        let presentation = DashboardPresentation(operation: operation, hasScanned: true, candidateCount: 10,
                                                 lowRiskCount: 5, awaitingConfirmation: false)
        #expect(presentation.isWorking && !presentation.canCleanNow)
        switch operation {
        case .scanning, .automaticScan: #expect(presentation.primaryAction == .scanProgress)
        case .advising: #expect(presentation.primaryAction == .advisorProgress)
        case .cleaning, .automaticCleanup: #expect(presentation.primaryAction == .cleanupProgress)
        case .idle: Issue.record("Expected a busy operation")
        }
    }

    @Test func confirmationIsAnInputStateRatherThanOngoingWork() {
        let presentation = DashboardPresentation(operation: .idle, hasScanned: true, candidateCount: 10,
                                                 lowRiskCount: 5, awaitingConfirmation: true)
        #expect(presentation.primaryAction == .confirmCleanup)
        #expect(!presentation.isWorking && !presentation.canCleanNow)
    }

    @Test(arguments: [AppOperation.idle, .scanning, .automaticScan, .advising, .cleaning, .automaticCleanup])
    func quitMenuAndApplicationTerminationProtectInFlightDeletion(operation: AppOperation) {
        let model = AppModel(store: Store(initialState: AppFeature.State(operation: operation)) { AppFeature() })
        let delegate = DiskSageAppDelegate(model: model)
        let item = NSMenuItem(title: "Quit", action: #selector(DiskSageAppDelegate.quitApplication), keyEquivalent: "q")
        let deleting = operation == .cleaning || operation == .automaticCleanup
        #expect(delegate.validateMenuItem(item) == !deleting)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == (deleting ? .terminateCancel : .terminateNow))
        #expect(model.isCleaning == deleting)
        if deleting { #expect(model.errorMessage != nil) }
    }
}
