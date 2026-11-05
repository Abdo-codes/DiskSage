import ComposableArchitecture
import Foundation

struct MCPRegistrationClient: DependencyKey, Sendable {
    var perform: @Sendable (MCPClient, String, Bool) async -> MCPRegistrationStatus
    static let liveValue = Self { await MCPRegistrationService.shared.perform(client: $0, path: $1, connect: $2) }
    static let testValue = Self { _, _, _ in .notInstalled }
}

extension DependencyValues {
    var mcpRegistration: MCPRegistrationClient {
        get { self[MCPRegistrationClient.self] }
        set { self[MCPRegistrationClient.self] = newValue }
    }
}

@Reducer
struct MCPIntegrationFeature {
    @ObservableState
    struct State: Equatable {
        var statuses: [MCPClient: MCPRegistrationStatus] = [:]
        var busy: Set<MCPClient> = []
    }
    enum Action: Equatable {
        case check(MCPClient, String)
        case connect(MCPClient, String)
        case finished(MCPClient, MCPRegistrationStatus)
    }
    @Dependency(\.mcpRegistration) var registration

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .check(client, path), let .connect(client, path):
                guard !state.busy.contains(client) else { return .none }
                let connect: Bool
                if case .connect = action {
                    guard state.statuses[client] == .notConfigured else { return .none }
                    connect = true
                } else { connect = false }
                state.busy.insert(client)
                return .run { [registration] send in
                    let result = await registration.perform(client, path, connect)
                    await send(.finished(client, result))
                }
            case let .finished(client, status):
                state.busy.remove(client)
                state.statuses[client] = status
                return .none
            }
        }
    }
}
