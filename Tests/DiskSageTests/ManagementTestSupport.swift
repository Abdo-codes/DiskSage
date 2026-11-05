import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
enum ManagementTestSupport {
    static func request(_ name: String, _ args: [String: Any] = [:], id: Int = 100) throws -> AgentToolRequest {
        var args = args
        if MCPManagementSchema.definitions.first(where: { $0.name == name })?.requestID == true {
            args["request_id"] = FeatureTestSupport.id(id).uuidString
        }
        let command = try MCPManagementSchema.command(name: name, arguments: args)
        return try #require(command)
    }
    static func store(_ state: AppFeature.State = .init(),
                      _ dependencies: @escaping (inout DependencyValues) -> Void = { _ in }) -> StoreOf<AppFeature> {
        Store(initialState: state) { AppFeature() } withDependencies: {
            $0.date = .constant(FeatureTestSupport.epoch); $0.uuid = .incrementing; $0.calendar = .current
            $0.diskSage = .testValue; $0.schedules = .testValue; $0.management = .testValue
            dependencies(&$0)
        }
    }
    static func initial() -> AppFeature.State {
        var state = AppFeature.State(); state.schedulesLoaded = true
        return state
    }
    static var createArguments: [String: Any] {
        ["target": "folder", "path": "/fixture/Generated/.build", "frequency": "daily", "hour": 2, "minute": 0]
    }
    static func result(_ store: StoreOf<AppFeature>, _ id: Int = 100) -> [String: ToolValue] {
        store.agentToolJobs[FeatureTestSupport.id(id)]?.result?.object ?? [:]
    }
}
