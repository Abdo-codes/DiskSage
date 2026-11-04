import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    var candidates: [CleanupCandidate] = []
    var selection = Set<CleanupCandidate.ID>()
    var recommendations: [CleanupCandidate.ID: AgentRecommendation] = [:]
    var recommendationSummary = ""
    var isScanning = false
    var isAdvising = false
    var isCleaning = false
    var statusMessage = "Ready to scan"
    var errorMessage: String?
    var lastRecoveredBytes: Int64 = 0
    var freeSpaceBytes: Int64 = 0

    private let scanner = DiskScanner()
    private let cleaner = CleanupService()
    private let advisor = CodexAdvisor()

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
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        statusMessage = "Scanning generated files…"

        Task {
            let results = await scanner.scan()
            candidates = results
            selection = Set(results.filter { $0.risk == .low }.map(\.id))
            recommendations = [:]
            recommendationSummary = ""
            freeSpaceBytes = Self.currentFreeSpace()
            statusMessage = results.isEmpty ? "Nothing reclaimable found" : "Found \(results.count) candidates"
            isScanning = false
        }
    }

    func askCodex(executablePath: String, model: String) {
        guard !candidates.isEmpty, !isAdvising else { return }
        isAdvising = true
        errorMessage = nil
        statusMessage = "Codex is reviewing metadata…"

        Task {
            do {
                let response = try await advisor.recommend(
                    candidates: candidates,
                    executablePath: executablePath,
                    model: model
                )
                recommendations = Dictionary(uniqueKeysWithValues: response.recommendations.map { ($0.id, $0) })
                recommendationSummary = response.summary
                let safeAgentChoices = candidates.filter {
                    recommendations[$0.id]?.decision == .delete && $0.risk != .high
                }
                selection = Set(safeAgentChoices.map(\.id))
                statusMessage = "Agent review complete"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Agent review failed"
            }
            isAdvising = false
        }
    }

    func deleteSelection() {
        let targets = selectedCandidates
        guard !targets.isEmpty, !isCleaning else { return }
        isCleaning = true
        errorMessage = nil
        statusMessage = "Deleting approved candidates…"

        Task {
            do {
                lastRecoveredBytes = try await cleaner.delete(targets)
                selection.removeAll()
                statusMessage = "Recovered approximately \(lastRecoveredBytes.diskSize)"
                candidates = await scanner.scan()
                freeSpaceBytes = Self.currentFreeSpace()
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Cleanup stopped safely"
            }
            isCleaning = false
        }
    }

    private static func currentFreeSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: "/System/Volumes/Data")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
