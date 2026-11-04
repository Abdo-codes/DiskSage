import Foundation
import Observation

enum AppOperation: Equatable {
    case idle
    case scanning
    case advising
    case cleaning
    case automaticCleanup
}

@Observable
@MainActor
final class AppModel {
    var candidates: [CleanupCandidate] = []
    var selection = Set<CleanupCandidate.ID>()
    var recommendations: [CleanupCandidate.ID: AgentRecommendation] = [:]
    var recommendationSummary = ""
    var operation: AppOperation = .idle
    var statusMessage = "Ready to scan"
    var errorMessage: String?
    var lastRecoveredBytes: Int64 = 0
    var freeSpaceBytes: Int64 = 0
    var lastAutomaticCleanup: Date?
    var automaticCleanupSummary = "No automatic cleanup has run"

    var cleanupFailures: [CleanupItemResult] = []

    @ObservationIgnored private let scanner = DiskScanner()
    @ObservationIgnored private let cleaner = CleanupService()
    @ObservationIgnored private let advisor = CodexAdvisor()
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = UUID()

    init() {
        freeSpaceBytes = Self.currentFreeSpace()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorLoop()
        }
    }

    var isScanning: Bool { operation == .scanning }
    var isAdvising: Bool { operation == .advising }
    var isCleaning: Bool { operation == .cleaning || operation == .automaticCleanup }
    var isBusy: Bool { operation != .idle }

    var selectedCandidates: [CleanupCandidate] {
        candidates.filter { selection.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.size }
    }

    var totalCandidateBytes: Int64 {
        candidates.reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard operation == .idle else { return }
        operation = .scanning
        errorMessage = nil
        statusMessage = "Scanning generated files…"
        let generation = UUID()
        scanGeneration = generation

        operationTask = Task {
            let results = await scanner.scan()
            guard !Task.isCancelled, scanGeneration == generation else { return }
            candidates = results
            selection = Set(results.filter { $0.risk == .low }.map(\.id))
            recommendations = [:]
            recommendationSummary = ""
            freeSpaceBytes = Self.currentFreeSpace()
            statusMessage = results.isEmpty ? "Nothing reclaimable found" : "Found \(results.count) candidates"
            operation = .idle
            operationTask = nil
        }
    }

    func askCodex(executablePath: String, model: String) {
        guard !candidates.isEmpty, operation == .idle else { return }
        operation = .advising
        errorMessage = nil
        statusMessage = "Codex is reviewing metadata…"

        let generation = scanGeneration
        operationTask = Task {
            do {
                let response = try await advisor.recommend(
                    candidates: candidates,
                    executablePath: executablePath,
                    model: model
                )
                guard !Task.isCancelled, scanGeneration == generation else { return }
                recommendations = response.recommendations.reduce(into: [:]) { result, recommendation in
                    result[recommendation.id] = recommendation
                }
                recommendationSummary = response.summary
                let safeAgentChoices = candidates.filter {
                    recommendations[$0.id]?.decision == .delete && $0.risk == .low
                }
                selection = Set(safeAgentChoices.map(\.id))
                statusMessage = "Agent review complete"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Agent review failed"
            }
            operation = .idle
            operationTask = nil
        }
    }

    func deleteSelection() {
        let targets = selectedCandidates
        guard !targets.isEmpty, operation == .idle else { return }
        operation = .cleaning
        errorMessage = nil
        statusMessage = "Deleting approved candidates…"

        operationTask = Task {
            let report = await cleaner.delete(targets)
            let succeededIDs = Set(report.items.filter(\.succeeded).map(\.candidate.id))
            selection.subtract(succeededIDs)
            cleanupFailures = report.failures
            lastRecoveredBytes = report.actualRecoveredBytes
            candidates = await scanner.scan()
            freeSpaceBytes = report.freeSpaceAfter

            if report.failures.isEmpty {
                statusMessage = "Recovered \(report.actualRecoveredBytes.diskSize)"
            } else {
                errorMessage = "\(report.failures.count) item(s) could not be removed."
                statusMessage = "Recovered \(report.actualRecoveredBytes.diskSize) with warnings"
            }
            operation = .idle
            operationTask = nil
        }
    }

    func cancelCurrentOperation() {
        operationTask?.cancel()
        operationTask = nil
        scanGeneration = UUID()
        operation = .idle
        statusMessage = "Operation cancelled"
    }

    private func monitorLoop() async {
        while !Task.isCancelled {
            await checkAutomaticCleanup()
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    private func checkAutomaticCleanup() async {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "automaticCleanupEnabled") as? Bool ?? true
        let thresholdGiB = defaults.object(forKey: "cleanupThresholdGiB") as? Int ?? 15
        let available = Self.currentFreeSpace()
        freeSpaceBytes = available

        guard enabled,
              available <= Int64(thresholdGiB) * 1_024 * 1_024 * 1_024,
              operation == .idle else { return }

        operation = .automaticCleanup
        statusMessage = "Low disk space detected; cleaning safe items…"
        let scanned = await scanner.scan()
        let safeTargets = scanned.filter { $0.risk == .low }
        let report = await cleaner.delete(safeTargets)
        candidates = await scanner.scan()
        selection = Set(candidates.filter { $0.risk == .low }.map(\.id))
        cleanupFailures = report.failures
        lastRecoveredBytes = report.actualRecoveredBytes
        freeSpaceBytes = report.freeSpaceAfter
        lastAutomaticCleanup = Date()
        automaticCleanupSummary = report.failures.isEmpty
            ? "Recovered \(report.actualRecoveredBytes.diskSize)"
            : "Recovered \(report.actualRecoveredBytes.diskSize); \(report.failures.count) item(s) failed"
        statusMessage = automaticCleanupSummary
        operation = .idle
    }

    private static func currentFreeSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: "/System/Volumes/Data")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
