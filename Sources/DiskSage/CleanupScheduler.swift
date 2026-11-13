import Foundation

/// Owns scheduling and log order. Workers only delete targets already authorized by a durable log event.
struct CleanupScheduler {
    let service: CleanupService
    let candidates: [CleanupCandidate]
    let trigger: CleanupTrigger
    let updates: AsyncStream<CleanupProgress>.Continuation

    private struct Completed: Sendable {
        let index: Int
        let result: CleanupItemResult
    }

    func run() async -> CleanupReport {
        let runID = UUID()
        let before = CleanupDiskSpace.read()
        let entries = ParallelCleanupEntries(updates: updates)
        var results: [Int: CleanupItemResult] = [:]
        var loggingError: String?
        do {
            try service.writeEvent(CleanupLogEvent(runID: runID, trigger: trigger, event: .started,
                freeSpaceBefore: before, candidateCount: candidates.count))
        } catch { loggingError = logFailure(error) }

        await withTaskGroup(of: Completed.self) { group in
            var pending = Array(candidates.indices)
            var active = Set<Int>()
            while !pending.isEmpty || !active.isEmpty {
                while loggingError == nil, active.count < service.maximumWorkers,
                      let offset = readyOffset(pending: pending, active: active) {
                    let index = pending.remove(at: offset)
                    let candidate = candidates[index]
                    do {
                        try service.writeEvent(CleanupLogEvent(runID: runID, trigger: trigger, event: .itemStarted,
                            path: candidate.url.path, name: candidate.name))
                    } catch {
                        loggingError = logFailure(error)
                        break
                    }
                    active.insert(index)
                    updates.yield(.started(candidate, completed: results.count, total: candidates.count))
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: trigger == .automatic || trigger == .scheduled ? .utility : .userInitiated).async {
                                let counter = CleanupEntryCounter { entries.record(index: index, count: $0) }
                                let result: CleanupItemResult
                                do {
                                    let removal = try service.remove(candidate) { counter.recordRemoved() }
                                    result = CleanupItemResult(candidate: candidate, removedBytes: removal?.removedBytes ?? candidate.size,
                                                               errorDescription: nil, note: removal?.note)
                                } catch let error as PartialCleanupFailure {
                                    result = CleanupItemResult(candidate: candidate, removedBytes: error.removedBytes, errorDescription: error.localizedDescription)
                                } catch {
                                    result = CleanupItemResult(candidate: candidate, removedBytes: 0, errorDescription: error.localizedDescription)
                                }
                                counter.flush()
                                continuation.resume(returning: Completed(index: index, result: result))
                            }
                        }
                    }
                }
                guard !active.isEmpty, let completed = await group.next() else { break }
                active.remove(completed.index)
                results[completed.index] = completed.result
                entries.publish()
                updates.yield(.finished(completed.result, completed: results.count, total: candidates.count))
                do {
                    try service.writeEvent(CleanupLogEvent(runID: runID, trigger: trigger, event: .itemFinished,
                        path: completed.result.candidate.url.path, name: completed.result.candidate.name,
                        succeeded: completed.result.succeeded, message: completed.result.errorDescription ?? completed.result.note,
                        estimatedRemovedBytes: completed.result.removedBytes))
                } catch { if loggingError == nil { loggingError = logFailure(error) } }
            }
        }
        var report = CleanupReport(items: results.keys.sorted().compactMap { results[$0] }, freeSpaceBefore: before,
            freeSpaceAfter: CleanupDiskSpace.read(), loggingError: loggingError, removedEntryCount: entries.total)
        do {
            try service.writeEvent(CleanupLogEvent(runID: runID, trigger: trigger, event: .finished,
                succeeded: report.failures.isEmpty && loggingError == nil, message: loggingError,
                estimatedRemovedBytes: report.estimatedRemovedBytes, actualRecoveredBytes: report.actualRecoveredBytes,
                freeSpaceBefore: before, freeSpaceAfter: report.freeSpaceAfter, candidateCount: results.count,
                failedCount: report.failures.count, removedEntryCount: entries.total))
        } catch { report.loggingError = "Cleanup summary could not be logged: \(error.localizedDescription)" }
        return report
    }

    private func readyOffset(pending: [Int], active: Set<Int>) -> Int? {
        for (offset, index) in pending.enumerated() {
            // Preserve input order for overlapping paths and global simulator operations.
            let predecessors = Array(active) + Array(pending.prefix(offset))
            if !predecessors.contains(where: { Self.conflicts(candidates[index], candidates[$0]) }) { return offset }
        }
        return nil
    }

    static func conflicts(_ lhs: CleanupCandidate, _ rhs: CleanupCandidate) -> Bool {
        if lhs.deletionMode == .simulatorDevices || rhs.deletionMode == .simulatorDevices { return true }
        // CoreSimulator handles one delete at a time more reliably.
        if lhs.deletionMode == .simulatorDevice && rhs.deletionMode == .simulatorDevice { return true }
        if lhs.identity.device != 0, lhs.identity == rhs.identity { return true }
        // Conservative on both case-sensitive and case-insensitive volumes; never resolve symlinks to schedule work.
        let a = lhs.url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        let b = rhs.url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private func logFailure(_ error: Error) -> String {
        "Cleanup stopped scheduling new targets because its log could not be written. Already-started targets finish: \(error.localizedDescription)"
    }
}

private enum CleanupDiskSpace {
    static func read() -> Int64 {
        let values = try? URL(fileURLWithPath: "/System/Volumes/Data")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
