import ComposableArchitecture
import Foundation

enum AppOperation: Equatable, Sendable {
    case idle, scanning, automaticScan, advising, cleaning, automaticCleanup
}

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var candidates: [CleanupCandidate] = []
        var selection = Set<UUID>()
        var recommendations: [UUID: AgentRecommendation] = [:]
        var recommendationSummary = ""
        var operation: AppOperation = .idle
        var operationID: UUID?
        var statusMessage = "Ready to scan"
        var errorMessage: String?
        var lastRecoveredBytes: Int64 = 0
        var freeSpaceBytes: Int64 = 0
        var lastAutomaticCleanup: Date?
        var automaticCleanupSummary = "No automatic cleanup has run"
        var diskUsage: DiskUsageSnapshot?
        var recentActivity: [CleanupRunSummary] = []
        var activityError: String?
        var lastScanDate: Date?
        var cleanupFailures: [CleanupItemResult] = []
        var cleanupRemovedEntryCount = 0
        var cleanupCompletedCount = 0
        var cleanupTotalCount = 0
        var cleanupCurrentItem = ""
        var cleanupActiveItems: [UUID: String] = [:]
        var cleanupReport: CleanupReport?
        var pendingDeletionRequest: DeletionRequest?
        var agentToolJobs: [UUID: AgentToolJob] = [:]
        var agentToolJobOrder: [UUID] = []
        var activeAgentToolJobID: UUID?
        var agentToolConnectionError: String?
        var agentToolReply: AgentToolReply?
        var isMonitoring = false
        var automaticCheckID: UUID?
        var automaticRetryAfter: Date?
        var storageNotifications = DiskSpaceNotificationObserver.Status()
        var activityRevision = 0
        var dashboardRevision = 0
        var schedules: [CleanupSchedule] = []
        var schedulesLoaded = false
        var isScheduling = false
        var scheduleError: String?
        var schedulingBlocked = false
        var activeSchedule: ScheduledCleanupRun?
        var pendingManagementApproval: ManagementApproval?
        var managedRequests: [UUID: AgentToolRequest] = [:]
        var lastMCPContact: Date?
        var worktrees = WorktreesFeature.State()

        var isScanning: Bool { operation == .scanning || operation == .automaticScan }
        var isAdvising: Bool { operation == .advising }
        var isCleaning: Bool { operation == .cleaning || operation == .automaticCleanup || worktrees.removing }
        var isBusy: Bool { operation != .idle || pendingDeletionRequest != nil || pendingManagementApproval != nil || worktrees.isBusy }
        var lowRiskCandidates: [CleanupCandidate] { candidates.filter { $0.risk == .low } }
        var selectedCandidates: [CleanupCandidate] { candidates.filter { selection.contains($0.id) } }
        var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.size } }
        var totalCandidateBytes: Int64 { candidates.reduce(0) { $0 + $1.size } }
    }

    enum ScanPurpose: Equatable, Sendable { case review, manualLowRisk, agent(UUID), automatic }
    enum Action: Equatable, Sendable {
        case scanRequested(ScanPurpose)
        case scanFinished(UUID, ScanPurpose, [CleanupCandidate], Int64, DashboardSnapshot)
        case advisorRequested(AgentConfiguration)
        case advisorFinished(UUID, AgentConfiguration, Result<AgentResponse, FeatureFailure>)
        case deleteApproved([CleanupCandidate], CleanupTrigger)
        case cleanupProgress(UUID, CleanupProgress)
        case cleanupFinished(UUID, CleanupReport, DashboardSnapshot)
        case requestDeletion([CleanupCandidate])
        case requestLowRiskCleanup
        case confirmDeletion(UUID)
        case dismissConfirmation
        case cancelOperation
        case selectionChanged(Set<UUID>)
        case presentationError(String?)
        case toolConnectionChanged(String?)
        case agentToolRequest(AgentToolRequest)
        case refreshDashboard
        case dashboardLoaded(Int, DashboardSnapshot)
        case startMonitoring
        case stopMonitoring
        case monitorTick
        case monitoringPreferencesChanged
        case storageNotificationsChanged(DiskSpaceNotificationObserver.Status)
        case capacityRead(UUID, Int, Bool, Int64)
        case automaticCheckLogged(UUID, Bool, FeatureFailure?)
        case openLogs
        case startScheduling
        case stopScheduling
        case scheduleTick
        case saveSchedule(CleanupSchedule)
        case setScheduleEnabled(UUID, Bool)
        case removeSchedule(UUID)
        case scheduledScanFinished(UUID, Result<[CleanupCandidate], FeatureFailure>)
        case approveManagement(UUID)
        case rejectManagement(UUID)
        case managementFinished(UUID, Result<ToolValue, FeatureFailure>)
        case agentClientContact
        case worktrees(WorktreesFeature.Action)
    }

    enum CancelID { case scan, advisor, dashboard, monitor, monitorCheck, schedules }
    @Dependency(\.diskSage) var client
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock
    @Dependency(\.schedules) var schedules
    @Dependency(\.calendar) var calendar
    @Dependency(\.management) var management
    @Dependency(\.worktrees) var worktreeClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .worktrees(action): return reduceWorktrees(state: &state, action: action)
            case .scanRequested, .scanFinished, .advisorRequested, .advisorFinished, .cancelOperation:
                return reduceOperations(state: &state, action: action)
            case .deleteApproved, .cleanupProgress, .cleanupFinished, .requestDeletion,
                 .requestLowRiskCleanup, .confirmDeletion, .dismissConfirmation:
                return reduceCleanup(state: &state, action: action)
            case let .agentToolRequest(request): return handleAgentRequest(state: &state, request: request)
            case .agentClientContact:
                state.lastMCPContact = now
                return .none
            case let .storageNotificationsChanged(status):
                state.storageNotifications = status
                return .none
            case .approveManagement, .rejectManagement, .managementFinished:
                return reduceManagement(state: &state, action: action)
            case .startMonitoring, .stopMonitoring, .monitorTick, .monitoringPreferencesChanged, .capacityRead, .automaticCheckLogged:
                return reduceMonitoring(state: &state, action: action)
            case .startScheduling, .stopScheduling, .scheduleTick, .saveSchedule,
                 .setScheduleEnabled, .removeSchedule, .scheduledScanFinished:
                return reduceSchedules(state: &state, action: action)
            case let .selectionChanged(selection): state.selection = selection; return .none
            case let .presentationError(error): state.errorMessage = error; return .none
            case let .toolConnectionChanged(error): state.agentToolConnectionError = error; return .none
            case .refreshDashboard: return refreshDashboard(state: &state)
            case let .dashboardLoaded(revision, snapshot):
                guard revision == state.dashboardRevision else { return .none }
                state.apply(snapshot)
                return .none
            case .openLogs:
                return .run { [client] send in
                    if let error = await client.openLogs() { await send(.presentationError(error)) }
                }
            }
        }
    }

    func refreshDashboard(state: inout State) -> EffectOf<Self> {
        state.dashboardRevision += 1
        let revision = state.dashboardRevision
        return .run { [client] send in
            let snapshot = await client.dashboard()
            guard !Task.isCancelled else { return }
            await send(.dashboardLoaded(revision, snapshot))
        }.cancellable(id: CancelID.dashboard, cancelInFlight: true)
    }
}

extension AppFeature.State {
    mutating func apply(_ snapshot: DashboardSnapshot) {
        diskUsage = snapshot.usage
        recentActivity = snapshot.history
        activityError = snapshot.historyError
    }
}
