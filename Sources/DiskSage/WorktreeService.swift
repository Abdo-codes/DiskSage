import Foundation

struct WorktreeInventory: Equatable, Sendable {
    var items: [WorktreeInspection] = []
    var warnings: [String] = []
    var scopedCommonDirectory: String?
}

struct WorktreeService: Sendable {
    var inspector = WorktreeInspector()
    var repository = WorktreeRepository.standard
    var logger = CleanupLogger.shared
    /// The largest number of folders that discovery opens under one approved folder.
    var discoveryFolderLimit = 200_000

    func inventory(_ configuration: WorktreeConfiguration, repositoryRoot: String? = nil) throws -> WorktreeInventory {
        let roots: [String]
        if let root = repositoryRoot {
            _ = try WorktreePathGuard.identity(root)
            guard configuration.roots.contains(where: { WorktreePathGuard.contains($0, root) }),
                  FileManager.default.fileExists(atPath: root + "/.git") else {
                throw FeatureFailure(message: "Choose a repository inside an already-approved worktree folder.")
            }
            roots = [root]
        } else { roots = configuration.roots }
        var result = WorktreeInventory(), repositories = Set<String>()
        var scanner = inspector
        if inspector.checkActivity, !roots.isEmpty {
            scanner.processPaths = try WorktreeActivity.capture(inspector.git)
        }
        for root in roots {
            do {
                _ = try WorktreePathGuard.identity(root)
                var candidates = [root], visited = 0
                if !FileManager.default.fileExists(atPath: root + "/.git"), let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [], errorHandler: { url, error in result.warnings.append("\(url.path): \(error.localizedDescription)"); return false }) {
                    for case let url as URL in walker {
                        guard !Task.isCancelled else { throw CancellationError() }
                        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        // Only folders count. A folder with many loose files must not hide the repositories after it.
                        if values.isDirectory == true { visited += 1 }
                        guard visited <= discoveryFolderLimit else {
                            // Keep the repositories found before the limit, and say that the list is not complete.
                            result.warnings.append("\(root): more than \(discoveryFolderLimit) folders. Some repositories are not in the list; choose a narrower folder.")
                            break
                        }
                        if values.isSymbolicLink == true { continue } // The enumerator does not follow links.
                        if values.isDirectory == true, FileManager.default.fileExists(atPath: url.appending(path: ".git").path) {
                            candidates.append(url.path); walker.skipDescendants(); continue
                        }
                        if url.lastPathComponent == ".git" {
                            candidates.append(url.deletingLastPathComponent().path)
                            if values.isDirectory == true { walker.skipDescendants() }
                            continue
                        }
                        let depth = url.pathComponents.count - URL(fileURLWithPath: root).pathComponents.count
                        if values.isDirectory == true,
                           depth > 5 || [".build", "build", "node_modules", ".cache", "vendor", "Pods"].contains(url.lastPathComponent) { walker.skipDescendants() }
                    }
                }
                for path in Set(candidates).sorted() {
                    guard FileManager.default.fileExists(atPath: path + "/.git") else { continue }
                    do {
                        let common = try inspector.git.text(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
                        _ = try WorktreePathGuard.identity(common)
                        if repositoryRoot != nil { result.scopedCommonDirectory = common }
                        guard repositories.insert(common).inserted else { continue }
                        let rows = try WorktreeParsing.records(inspector.git.run(path, ["worktree", "list", "--porcelain", "-z"]).data, common: common)
                        let linked = rows.filter { !$0.main }
                        guard !linked.isEmpty else { continue }
                        guard rows.count <= 100, result.items.filter({ !$0.worktree.main }).count + linked.count <= 300 else {
                            throw FeatureFailure(message: "Inventory limit exceeded (100 worktrees per repository, 300 linked checkouts total). Choose a narrower folder.")
                        }
                        do {
                            try WorktreeObjectPolicy.validateShared(common: common)
                            scanner.sharedObjectChecks[common] = .passed
                        } catch {
                            scanner.sharedObjectChecks[common] = .failed(FeatureFailure(message: error.localizedDescription))
                        }
                        for row in rows {
                            guard !Task.isCancelled else { throw CancellationError() }
                            result.items.append(scanner.inspect(row, configuration: configuration))
                        }
                    } catch { result.warnings.append("\(path): \(error.localizedDescription)") }
                }
            } catch { result.warnings.append("\(root): \(error.localizedDescription)") }
        }
        if repositoryRoot != nil, result.scopedCommonDirectory == nil {
            throw FeatureFailure(message: result.warnings.first ?? "The requested Git repository could not be inspected.")
        }
        result.items.sort { ($0.worktree.commonDirectory, $0.worktree.path) < ($1.worktree.commonDirectory, $1.worktree.path) }
        return result
    }

    func remove(_ preview: WorktreePreview) -> [WorktreeResult] {
        defer { WorktreeCancellation.shared.finish(preview.id) }
        var results: [WorktreeResult] = []
        let before = DiskSageClient.availableSpace()
        do {
            guard !preview.items.isEmpty, preview.items.count <= WorktreeQuickCleanup.batchLimit, preview.items.allSatisfy(\.canRequestRemoval), preview.protectionChange == nil else {
                throw FeatureFailure(message: "Invalid removal approval.")
            }
            guard !preview.requiresIgnoredApproval || preview.ignoredFilesApproved == true else {
                throw FeatureFailure(message: "Ignored files require explicit approval in DiskSage before checkout removal.")
            }
            guard !preview.requiresDiscardApproval || preview.discardChangesApproved == true else {
                throw FeatureFailure(message: "Discarding worktree data requires separate explicit approval in DiskSage.")
            }
            try repository.intent(preview)
            try logger.append(CleanupLogEvent(runID: preview.id, trigger: preview.toolRequestID == nil ? .manual : .agent,
                event: .started, message: "Git checkout removal; branches retained.", freeSpaceBefore: before, candidateCount: preview.items.count))
        } catch { return preview.items.map { WorktreeResult(id: $0.id, path: $0.worktree.path, succeeded: false, message: "Nothing removed: \(error.localizedDescription)") } }
        // Sequential mutations also serialize checkouts sharing the same common repository.
        for approved in preview.items {
            var succeeded = false, message = ""
            do {
                guard !WorktreeCancellation.shared.contains(preview.id) else {
                    throw FeatureFailure(message: "Queued removal cancelled. No Git removal was started for this checkout.")
                }
                let configuration = try repository.configuration()
                let path = approved.worktree.path
                let listed = try WorktreeParsing.records(inspector.git.run(approved.worktree.commonDirectory,
                    ["worktree", "list", "--porcelain", "-z"]).data, common: approved.worktree.commonDirectory)
                guard let current = listed.first(where: { $0.id == approved.id }), current == approved.worktree else {
                    throw FeatureFailure(message: "Worktree registration changed; review again.")
                }
                let checked = inspector.inspect(current, configuration: configuration)
                guard checked.canRequestRemoval, checked.fingerprint == approved.fingerprint else {
                    throw FeatureFailure(message: "Evidence changed or became unsafe; refresh and review again. \(checked.blockers.joined(separator: " "))")
                }
                try logger.append(CleanupLogEvent(runID: preview.id, trigger: preview.toolRequestID == nil ? .manual : .agent,
                    event: .itemStarted, path: path, name: "Worktree: \(URL(fileURLWithPath: path).lastPathComponent)", message: "HEAD \(current.head); retained refs \(checked.retainedRefs.keys.sorted().joined(separator: ", ")); ignored files approved: \(preview.ignoredFilesApproved == true), count \(checked.ignoredFileCount), estimated bytes \(checked.ignoredBytes); discard approved: \(preview.discardChangesApproved == true); risks: \(checked.discardReasons.joined(separator: " "))"))
                // One force flag is permitted only for an exact, separately approved discard preview.
                // Never unlock, double-force, prune or recursively fall back after Git refuses.
                let discard = checked.requiresDiscardApproval && preview.discardChangesApproved == true
                _ = try inspector.git.run(current.commonDirectory, ["worktree", "remove"] + (discard ? ["--force"] : []) + ["--", path])
                let remaining = try WorktreeParsing.records(inspector.git.run(current.commonDirectory,
                    ["worktree", "list", "--porcelain", "-z"]).data, common: current.commonDirectory)
                guard !remaining.contains(where: { $0.id == current.id }), !FileManager.default.fileExists(atPath: path) else {
                    throw FeatureFailure(message: "Git returned but the checkout/registration remains. Review the partial result; no retry was made.")
                }
                // Remote default branches are retained too (see WorktreeInspector), so read remote refs as well.
                let refLines = try inspector.git.text(current.commonDirectory, ["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags", "refs/remotes"])
                let retained = Dictionary(uniqueKeysWithValues: refLines.split(separator: "\n").compactMap { line -> (String, String)? in
                    let fields = line.split(separator: " ", maxSplits: 1)
                    return fields.count == 2 ? (String(fields[0]), String(fields[1])) : nil
                })
                for (ref, oid) in checked.retainedRefs {
                    guard retained[ref] == oid else {
                        throw FeatureFailure(message: "Checkout removed but reference changed concurrently: \(ref). Inspect repository; no retry was made.")
                    }
                }
                succeeded = true
                message = "Checkout removed. Top-level branches and shared Git data retained."
            } catch { message = error.localizedDescription + " No fallback deletion was attempted; refresh to inspect any remaining checkout." }
            let result = WorktreeResult(id: approved.id, path: approved.worktree.path, succeeded: succeeded, message: message)
            results.append(result)
            do {
                try logger.append(CleanupLogEvent(runID: preview.id, trigger: preview.toolRequestID == nil ? .manual : .agent,
                    event: .itemFinished, path: result.path, name: "Worktree: \(URL(fileURLWithPath: result.path).lastPathComponent)", succeeded: succeeded,
                    message: message, estimatedRemovedBytes: succeeded ? approved.estimatedBytes : 0))
            } catch { results[results.count - 1].message += " Result logging failed: \(error.localizedDescription)"; break }
        }
        for item in preview.items where !results.contains(where: { $0.id == item.id }) {
            results.append(WorktreeResult(id: item.id, path: item.worktree.path, succeeded: false, message: "Not attempted after a logging failure. Inspect History before another request."))
        }
        let after = DiskSageClient.availableSpace()
        do {
            try logger.append(CleanupLogEvent(runID: preview.id, trigger: preview.toolRequestID == nil ? .manual : .agent, event: .finished,
                estimatedRemovedBytes: preview.items.filter { item in results.contains { $0.id == item.id && $0.succeeded } }.reduce(0) { $0 + $1.estimatedBytes },
                actualRecoveredBytes: max(0, after - before), freeSpaceBefore: before, freeSpaceAfter: after,
                candidateCount: preview.items.count, failedCount: preview.items.count - results.filter(\.succeeded).count))
        } catch { if !results.isEmpty { results[results.count - 1].message += " Summary logging failed: \(error.localizedDescription)" } }
        return results
    }
}
