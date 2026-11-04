import ComposableArchitecture
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureArbitrationTests {
    @Test(arguments: [AppOperation.scanning, .automaticScan, .advising, .cleaning, .automaticCleanup])
    func occupiedRootRejectsAllCompetingManualWork(operation: AppOperation) async {
        let target = FeatureTestSupport.candidate()
        let store = FeatureTestSupport.store(.init(candidates: [target], operation: operation,
                                                   operationID: FeatureTestSupport.id(99)))
        await store.send(.scanRequested(.review))
        await store.send(.advisorRequested(AgentConfiguration(provider: .claude)))
        await store.send(.deleteApproved([target], .manual))
        await store.send(.requestDeletion([target]))
        await store.send(.requestLowRiskCleanup)
        await store.finish()
    }
}
