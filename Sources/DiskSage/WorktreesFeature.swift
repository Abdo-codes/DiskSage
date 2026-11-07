import ComposableArchitecture
import Foundation

struct WorktreeClient: Sendable {
    var configuration: @Sendable () throws -> WorktreeConfiguration
    var saveConfiguration: @Sendable (WorktreeConfiguration) throws -> Void
    var inventory: @Sendable (WorktreeConfiguration, String?) async throws -> WorktreeInventory
    var cancel: @Sendable (UUID) -> Void
    var remove: @Sendable (WorktreePreview) async -> [WorktreeResult]
    var receipt: @Sendable (UUID) throws -> WorktreeReceipt?
    var saveReceipt: @Sendable (WorktreeReceipt) throws -> Void
}

extension WorktreeClient: DependencyKey {
    static let liveValue = Self(configuration: { try WorktreeRepository.standard.configuration() },
        saveConfiguration: { try WorktreeRepository.standard.save($0) },
        inventory: { configuration, root in
            let task = Task.detached(priority: .utility) { try WorktreeService().inventory(configuration, repositoryRoot: root) }
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        },
        cancel: { WorktreeCancellation.shared.request($0) },
        remove: { preview in await Task.detached(priority: .utility) { WorktreeService().remove(preview) }.value },
        receipt: { try WorktreeRepository.standard.receipt($0) }, saveReceipt: { try WorktreeRepository.standard.save($0) })
    static let testValue = Self(configuration: { WorktreeConfiguration() }, saveConfiguration: { _ in },
        inventory: { _, _ in WorktreeInventory() }, cancel: { _ in }, remove: { _ in [] }, receipt: { _ in nil }, saveReceipt: { _ in })
}
extension DependencyValues {
    var worktrees: WorktreeClient {
        get { self[WorktreeClient.self] }
        set { self[WorktreeClient.self] = newValue }
    }
}

@Reducer
struct WorktreesFeature {
    @ObservableState
    struct State: Equatable {
        var configuration = WorktreeConfiguration()
        var repositoryRoot: String?
        var scopedCommonDirectory: String?
        var requestedRepositoryRoot: String?
        var items: [WorktreeInspection] = []
        var warnings: [String] = []
        var selection: Set<String> = []
        var loading = false
        var loadID: UUID?
        var removing = false
        var cancelling = false
        var loaded = false
        var quickReviewRequested = false
        var error: String?
        var pending: WorktreePreview?
        // Execution belongs to the store, not the lifetime of a confirmation sheet.
        var activeRemoval: WorktreePreview?
        var toolPreviews: [UUID: WorktreePreview] = [:]
        var results: [WorktreeResult] = []
        var isBusy: Bool { loading || removing || pending != nil }
        var reviewItems: [WorktreeInspection] {
            guard repositoryRoot != nil else { return items }
            return items.filter { $0.worktree.commonDirectory == scopedCommonDirectory }
        }

        mutating func mergeInventory(_ inventory: WorktreeInventory) {
            repositoryRoot = requestedRepositoryRoot
            scopedCommonDirectory = inventory.scopedCommonDirectory
            warnings = inventory.warnings
            var updates = Dictionary(inventory.items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for index in items.indices {
                if let updated = updates.removeValue(forKey: items[index].id) {
                    items[index] = updated
                } else if repositoryRoot == nil || items[index].worktree.commonDirectory == scopedCommonDirectory {
                    let blocker = "Not found in the latest refresh. Inspect again before removal."
                    if !items[index].blockers.contains(blocker) { items[index].blockers.append(blocker) }
                }
            }
            items.append(contentsOf: inventory.items.compactMap { updates.removeValue(forKey: $0.id) })
            selection.formIntersection(Set(items.filter(\.canRequestRemoval).map(\.id)))
        }
    }
    enum Action: Equatable, Sendable {
        case load
        case loadRepository(String)
        case configurationLoaded(UUID, WorktreeConfiguration)
        case loaded(UUID, Result<WorktreeInventory, FeatureFailure>)
        case cancelLoad
        case addRoot(String)
        case removeRoot(String)
        case setIntegration(String, String)
        case select(Set<String>)
        case preview
        case reviewUnused
        case confirm(UUID, ignoredFilesApproved: Bool = false, discardChangesApproved: Bool = false)
        case dismiss
        case cancelQueued
        case setProtected(String, Bool)
        case removed([WorktreeResult])
    }
    enum CancelID { case inventory }
    @Dependency(\.worktrees) var client
    @Dependency(\.uuid) var uuid
    var body: some ReducerOf<Self> {
        Reduce { state, action in reduceAction(state: &state, action: action) }
    }
    func reduceAction(state: inout State, action: Action) -> EffectOf<Self> {
            do {
                switch action {
                case .load, .loadRepository:
                    guard !state.isBusy else { return .none }
                    if case let .loadRepository(root) = action { state.requestedRepositoryRoot = root } else { state.requestedRepositoryRoot = nil }
                    let id = uuid(); state.loadID = id
                    state.loading = true; state.error = nil; state.toolPreviews = [:]
                    return .run { [client, root = state.requestedRepositoryRoot] send in
                        do {
                            let configuration = try await Task.detached(priority: .utility) { try client.configuration() }.value
                            guard !Task.isCancelled else { return }
                            await send(.configurationLoaded(id, configuration))
                            let inventory = try await client.inventory(configuration, root)
                            if !Task.isCancelled { await send(.loaded(id, .success(inventory))) }
                        } catch {
                            if !Task.isCancelled { await send(.loaded(id, .failure(FeatureFailure(message: error.localizedDescription)))) }
                        }
                    }.cancellable(id: CancelID.inventory, cancelInFlight: true)
                case let .configurationLoaded(id, configuration):
                    guard state.loadID == id, state.loading else { return .none }
                    state.configuration = configuration
                case .cancelLoad:
                    guard state.loading else { return .none }
                    state.loading = false; state.loadID = nil; state.quickReviewRequested = false
                    state.requestedRepositoryRoot = nil
                    return .cancel(id: CancelID.inventory)
                case let .loaded(id, result):
                    guard state.loadID == id, state.loading else { return .none }
                    state.loading = false; state.loadID = nil; state.loaded = true
                    switch result {
                    case let .success(inventory):
                        state.mergeInventory(inventory)
                    case let .failure(error): state.error = error.message
                    }
                    state.requestedRepositoryRoot = nil
                    if state.quickReviewRequested {
                        state.quickReviewRequested = false
                        if state.error == nil { return .send(.reviewUnused) }
                    }
                case let .addRoot(path):
                    guard !state.isBusy else { return .none }
                    let root = CleanupPath.fileURL(URL(fileURLWithPath: path)).path
                    _ = try WorktreePathGuard.identity(root)
                    guard root != "/", !["/Users", "/Volumes", "/private", "/System"].contains(root) else { throw FeatureFailure(message: "Choose a specific repository or projects folder.") }
                    if !state.configuration.roots.contains(root) { state.configuration.roots.append(root) }
                    try client.saveConfiguration(state.configuration)
                    return .send(.load)
                case let .removeRoot(path):
                    guard !state.isBusy else { return .none }
                    var configuration = state.configuration
                    configuration.roots.removeAll { $0 == path }
                    try client.saveConfiguration(configuration)
                    state.configuration = configuration
                    state.items.removeAll { item in
                        WorktreePathGuard.contains(path, item.worktree.path) &&
                            !configuration.roots.contains { WorktreePathGuard.contains($0, item.worktree.path) }
                    }
                    state.selection.formIntersection(Set(state.items.map(\.id)))
                    return .send(.load)
                case let .setIntegration(common, ref):
                    guard !state.isBusy else { return .none }
                    guard ref.isEmpty || ref.hasPrefix("refs/") && !ref.contains("\0") && !ref.contains("\n") else {
                        throw FeatureFailure(message: "Use a full reference, for example refs/heads/main.")
                    }
                    state.configuration.integrationRefs[common] = ref.isEmpty ? nil : ref
                    try client.saveConfiguration(state.configuration); return .send(.load)
                case let .select(ids):
                    state.selection = ids.intersection(Set(state.items.filter(\.canRequestRemoval).map(\.id)))
                case .reviewUnused:
                    guard !state.removing, state.pending == nil else { return .none }
                    if state.loading { state.quickReviewRequested = true; return .none }
                    if !state.loaded { state.quickReviewRequested = true; return .send(.load) }
                    state.error = nil
                    let preview = try WorktreeQuickCleanup.preview(state.reviewItems, id: uuid())
                    state.pending = preview
                    state.selection.subtract(state.reviewItems.map(\.id))
                    state.selection.formUnion(preview.items.map(\.id))
                case .preview:
                    guard !state.isBusy, !state.selection.isEmpty else { return .none }
                    let items = state.reviewItems.filter { state.selection.contains($0.id) }.map(WorktreeQuickCleanup.compactForReview)
                    guard !items.isEmpty else { return .none }
                    guard items.count <= WorktreeQuickCleanup.batchLimit else { throw FeatureFailure(message: "Review up to 300 checkouts at a time.") }
                    guard items.allSatisfy(\.canRequestRemoval) else { throw FeatureFailure(message: "Refresh and resolve safety blockers first.") }
                    try WorktreeQuickCleanup.validateSize(items)
                    state.pending = WorktreePreview(id: uuid(), items: items)
                case let .setProtected(id, protected):
                    guard !state.isBusy, let item = state.reviewItems.first(where: { $0.id == id }) else { return .none }
                    if !protected {
                        state.pending = WorktreePreview(id: uuid(), items: [item], protectionChange: false)
                    } else {
                        state.configuration.protectedIDs.insert(id); try client.saveConfiguration(state.configuration)
                        return .send(.load)
                    }
                case .cancelQueued:
                    if state.removing, !state.cancelling, let id = state.activeRemoval?.id { state.cancelling = true; client.cancel(id) }
                case .dismiss:
                    guard !state.removing else { return .none }
                    state.pending = nil; state.quickReviewRequested = false
                case let .confirm(id, ignoredFilesApproved, discardChangesApproved):
                    guard var pending = state.pending, pending.id == id, !state.removing else { return .none }
                    if pending.protectionChange == false {
                        var configuration = try client.configuration()
                        for item in pending.items { configuration.protectedIDs.remove(item.id) }
                        try client.saveConfiguration(configuration)
                        state.configuration = configuration; state.pending = nil
                        return .send(.load)
                    }
                    guard !pending.requiresIgnoredApproval || ignoredFilesApproved else {
                        throw FeatureFailure(message: "Review and explicitly confirm removal of the ignored files first.")
                    }
                    guard !pending.requiresDiscardApproval || discardChangesApproved else {
                        throw FeatureFailure(message: "Review and explicitly approve discarding the listed worktree data first.")
                    }
                    pending.ignoredFilesApproved = pending.requiresIgnoredApproval ? true : nil
                    pending.discardChangesApproved = pending.requiresDiscardApproval ? true : nil
                    state.activeRemoval = pending; state.pending = nil
                    state.removing = true; state.error = nil; state.results = []
                    return .run { [client, pending] send in await send(.removed(await client.remove(pending))) }
                case let .removed(results):
                    state.results = results; state.removing = false; state.cancelling = false; state.activeRemoval = nil
                    let removed = Set(results.filter(\.succeeded).map(\.id))
                    state.selection.subtract(removed)
                    state.items.removeAll { removed.contains($0.id) }
                    return .send(state.repositoryRoot.map(Action.loadRepository) ?? .load)
                }
            } catch { state.error = error.localizedDescription; state.quickReviewRequested = false }
            return .none
    }
}
