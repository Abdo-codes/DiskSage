import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
enum FeatureTestSupport {
    static let epoch = Date(timeIntervalSince1970: 0)
    static func id(_ number: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))! }
    static func candidate(_ name: String = "Fixture", risk: RiskLevel = .low) -> CleanupCandidate {
        CleanupCandidate(url: URL(fileURLWithPath: "/fixture/\(name)"), name: name, category: .build,
                         size: 4096, risk: risk, reason: "Generated output")
    }
    static func store(_ initial: AppFeature.State = .init(),
                      dependencies: (inout DependencyValues) -> Void = { _ in }) -> TestStoreOf<AppFeature> {
        TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date = .constant(epoch)
            $0.calendar = .current
            $0.diskSage = .testValue
            dependencies(&$0)
        }
    }
}
