import ComposableArchitecture
import Foundation
import Observation

/// Temporary AppKit/SwiftUI adapter. The store owns every workflow value and effect.
@dynamicMemberLookup
@Observable
@MainActor
final class AppModel {
    @ObservationIgnored let store: StoreOf<AppFeature>

    init(store: StoreOf<AppFeature>) { self.store = store }

    convenience init(monitoringEnabled: Bool = true) {
        self.init(store: Store(initialState: AppFeature.State()) { AppFeature() })
        if monitoringEnabled {
            store.send(.refreshDashboard)
            store.send(.startMonitoring)
            store.send(.startScheduling)
        }
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<AppFeature.State, Value>) -> Value {
        store.state[keyPath: keyPath]
    }

    var selection: Set<UUID> {
        get { store.selection }
        set { store.send(.selectionChanged(newValue)) }
    }
    var errorMessage: String? {
        get { store.errorMessage }
        set { store.send(.presentationError(newValue)) }
    }
    var scanWarnings: [String] { store.scanWarnings }
    var agentToolConnectionError: String? {
        get { store.agentToolConnectionError }
        set { store.send(.toolConnectionChanged(newValue)) }
    }

    func scan() { store.send(.scanRequested(.review)) }
    func askAgent(configuration: AgentConfiguration) { store.send(.advisorRequested(configuration)) }
    func deleteSelection() { store.send(.deleteApproved(store.selectedCandidates, .manual)) }
    func deleteApprovedCandidates(_ targets: [CleanupCandidate], trigger: CleanupTrigger = .manual) {
        store.send(.deleteApproved(targets, trigger))
    }
    func requestDeletion(_ targets: [CleanupCandidate]) { store.send(.requestDeletion(targets)) }
    func requestLowRiskCleanup() { store.send(.requestLowRiskCleanup) }
    func confirmDeletion(_ request: DeletionRequest) { store.send(.confirmDeletion(request.id)) }
    func cancelDeletionRequest() { store.send(.dismissConfirmation) }
    func cancelCurrentOperation() { store.send(.cancelOperation) }
    func refreshDashboard() { store.send(.refreshDashboard) }
    func openCleanupLogs() { store.send(.openLogs) }

    func handleAgentToolRequest(_ request: AgentToolRequest) -> AgentToolReply {
        store.send(.agentClientContact)
        store.send(.agentToolRequest(request))
        return store.agentToolReply ?? AgentToolReply(error: "DiskSage did not produce a tool reply.")
    }
}
