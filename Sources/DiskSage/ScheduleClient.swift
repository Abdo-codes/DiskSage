import ComposableArchitecture
import Foundation

struct ScheduleClient: Sendable {
    var load: @Sendable () throws -> [CleanupSchedule]
    var save: @Sendable ([CleanupSchedule]) throws -> Void
    var validate: @Sendable (CleanupSchedule) throws -> Void
    var scan: @Sendable (CleanupSchedule) async throws -> [CleanupCandidate]
    var cleanup: @Sendable (CleanupSchedule, [CleanupCandidate],
        @escaping @Sendable (CleanupProgress) async -> Void) async -> CleanupReport
}

extension ScheduleClient: DependencyKey {
    static let liveValue = Self(load: { try CleanupScheduleRepository.standard.load() },
        save: { try CleanupScheduleRepository.standard.save($0) },
        validate: { try ScheduledFolderPolicy.validate($0) },
        scan: { schedule in
            let task = Task.detached(priority: .utility) { try ScheduledFolderPolicy.scan(schedule) }
            return try await withTaskCancellationHandler {
                if Task.isCancelled { task.cancel() }
                return try await task.value
            } onCancel: { task.cancel() }
        },
        cleanup: { await ScheduledFolderPolicy.delete($0, candidates: $1, progress: $2) })
    static let testValue = Self(load: { [] }, save: { _ in }, validate: { _ in },
        scan: unimplemented("ScheduleClient.scan", placeholder: []),
        cleanup: unimplemented("ScheduleClient.cleanup", placeholder: CleanupReport(items: [], freeSpaceBefore: 0, freeSpaceAfter: 0)))
}

extension DependencyValues {
    var schedules: ScheduleClient {
        get { self[ScheduleClient.self] }
        set { self[ScheduleClient.self] = newValue }
    }
}
