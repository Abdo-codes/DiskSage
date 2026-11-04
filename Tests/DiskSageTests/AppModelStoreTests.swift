import ComposableArchitecture
import Observation
import Testing
@testable import DiskSage

@MainActor
struct AppModelStoreTests {
    @Test func facadeBindingsUpdateTheStoreAndParticipateInNativeObservation() {
        let target = FeatureTestSupport.candidate()
        let store = Store(initialState: AppFeature.State(candidates: [target])) { AppFeature() }
        let model = AppModel(store: store)
        let changed = LockIsolated(false)
        withObservationTracking {
            _ = model.selection
        } onChange: {
            changed.setValue(true)
        }
        model.selection = [target.id]
        #expect(store.selection == [target.id])
        #expect(model.selectedBytes == 4096)
        #expect(changed.value)
        model.errorMessage = "Presentation error"
        #expect(store.errorMessage == "Presentation error")
        model.agentToolConnectionError = "Offline"
        #expect(store.agentToolConnectionError == "Offline")
    }
}
