import Darwin
import Foundation
import os

/// Read-only headless CLI subcommands for DiskSage (`scan`, `--help`, `--version`).
/// Returns `nil` from `parse(_:)` for normal GUI launches (including macOS LaunchServices flags).
enum DiskSageCLI {
    struct ScanOptions: Equatable, Sendable {
        var json = false
        var risk: ReviewRiskFilter = .all
        var category: ReviewCategoryFilter = .all
        var sort: ReviewSortOrder = .largest
        var query = ""
        var limit: Int?
    }

    struct ExplainOptions: Equatable, Sendable {
        var path: String
        var json = false
    }

    enum Command: Equatable, Sendable {
        case scan(ScanOptions)
        case explain(ExplainOptions)
        case help
        case version
        case usageError(String)
    }

    struct Result: Equatable, Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    struct ScanJSON: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            let name: String
            let path: String
            let category: String
            let risk: String
            let sizeBytes: Int64
            let deletionMode: String
            let reason: String

            enum CodingKeys: String, CodingKey {
                case name, path, category, risk, reason
                case sizeBytes = "size_bytes"
                case deletionMode = "deletion_mode"
            }
        }

        let version: String
        let scannedAt: Date
        let freeSpaceBytes: Int64?
        let totalScannedCount: Int
        let matchedCount: Int
        let matchedBytes: Int64
        let warnings: [String]
        let candidates: [Item]

        enum CodingKeys: String, CodingKey {
            case version, warnings, candidates
            case scannedAt = "scanned_at"
            case freeSpaceBytes = "free_space_bytes"
            case totalScannedCount = "total_scanned_count"
            case matchedCount = "matched_count"
            case matchedBytes = "matched_bytes"
        }
    }

    static let usageText = """
    DiskSage — read-only developer disk scanner (deletions stay in the GUI / MCP approval flow)

    Usage:
      DiskSage                             Launch the menu-bar app
      DiskSage --mcp                       Run the stdio MCP bridge to the running app
      DiskSage scan [options]              Run a read-only scan and print results
      DiskSage explain <path> [--json]     Explain why a path is offered or skipped
      DiskSage --help | -h                 Show this help message
      DiskSage --version | -v              Show version information

    Scan options:
      --json                               Emit machine-readable JSON to stdout
      --risk <all|low|review>              Filter by risk level (default: all)
      --category <all|build|cache|simulator|archive>
                                           Filter by category (default: all)
      --sort <largest|name|risk>           Sort order (default: largest)
      --query, -q <text>                   Filter by name, path, or category
      --limit <1..1000>                    Limit the number of candidates shown
    """

    static func parse(_ arguments: [String]) -> Command? {
        guard let first = arguments.first else { return nil }
        switch first {
        case "--help", "-h", "help":
            return .help
        case "--version", "-v":
            guard arguments.count == 1 else {
                return .usageError("Unexpected argument for \(first): \(arguments[1]).\n\n\(usageText)\n")
            }
            return .version
        case "scan":
            return parseScan(Array(arguments.dropFirst()))
        case "explain":
            return parseExplain(Array(arguments.dropFirst()))
        default:
            // Leave empty launches and macOS LaunchServices/AppKit arguments (-psn_*, -NS*, etc.) to the GUI.
            return nil
        }
    }

    private static func parseScan(_ args: [String]) -> Command {
        var options = ScanOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--help", "-h":
                return .help
            case "--json":
                options.json = true
            case "--risk":
                guard index + 1 < args.count else { return error("Missing value for --risk.") }
                index += 1
                switch args[index].lowercased() {
                case "all": options.risk = .all
                case "low": options.risk = .lowRisk
                case "review": options.risk = .needsReview
                default: return error("Invalid --risk value '\(args[index])'. Expected all, low, or review.")
                }
            case "--category":
                guard index + 1 < args.count else { return error("Missing value for --category.") }
                index += 1
                switch args[index].lowercased() {
                case "all": options.category = .all
                case "build": options.category = .build
                case "cache": options.category = .cache
                case "simulator": options.category = .simulator
                case "archive": options.category = .archive
                default: return error("Invalid --category value '\(args[index])'. Expected all, build, cache, simulator, or archive.")
                }
            case "--sort":
                guard index + 1 < args.count else { return error("Missing value for --sort.") }
                index += 1
                switch args[index].lowercased() {
                case "largest": options.sort = .largest
                case "name": options.sort = .name
                case "risk": options.sort = .risk
                default: return error("Invalid --sort value '\(args[index])'. Expected largest, name, or risk.")
                }
            case "--query", "-q":
                guard index + 1 < args.count else { return error("Missing value for \(arg).") }
                index += 1
                options.query = args[index]
            case "--limit":
                guard index + 1 < args.count else { return error("Missing value for --limit.") }
                index += 1
                guard let value = Int(args[index]), (1...1_000).contains(value) else {
                    return error("Invalid --limit value '\(args[index])'. Expected an integer between 1 and 1000.")
                }
                options.limit = value
            default:
                return error("Unknown scan argument '\(arg)'.")
            }
            index += 1
        }
        return .scan(options)
    }

    private static func parseExplain(_ args: [String]) -> Command {
        var path: String?
        var json = false
        for arg in args {
            switch arg {
            case "--help", "-h":
                return .help
            case "--json":
                json = true
            default:
                if arg.hasPrefix("-") {
                    return error("Unknown explain argument '\(arg)'.")
                }
                guard path == nil else {
                    return error("Unexpected extra path argument '\(arg)'.")
                }
                path = arg
            }
        }
        guard let path else {
            return error("Missing path for explain. Example: DiskSage explain ~/Developer/app/node_modules")
        }
        return .explain(ExplainOptions(path: path, json: json))
    }

    private static func error(_ message: String) -> Command {
        .usageError("Error: \(message)\n\n\(usageText)\n")
    }

    static func run(
        _ command: Command,
        scan: @Sendable () async throws -> ScanReport = { try await DiskScanner(maximumCandidates: 1_000).report() },
        explain: @Sendable (String) async throws -> PathDiagnostic = { path in
            let activity = try CleanupActivity.capture()
            return PathDiagnostics.explain(path, activity: activity)
        },
        freeSpace: @Sendable () -> Int64? = { try? DiskUsageSnapshot.read().availableBytes },
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        version: String = AppInformation().displayVersion
    ) async -> Result {
        switch command {
        case .help:
            return Result(exitCode: 0, stdout: usageText + "\n", stderr: "")
        case .version:
            return Result(exitCode: 0, stdout: "DiskSage \(version)\n", stderr: "")
        case let .usageError(message):
            return Result(exitCode: 2, stdout: "", stderr: message)
        case let .explain(options):
            let diagnostic: PathDiagnostic
            do {
                diagnostic = try await explain(options.path)
            } catch {
                return Result(exitCode: 1, stdout: "", stderr: "Explain failed: \(error.localizedDescription)\n")
            }
            if options.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                do {
                    let data = try encoder.encode(diagnostic)
                    return Result(exitCode: 0, stdout: String(decoding: data, as: UTF8.self) + "\n", stderr: "")
                } catch {
                    return Result(exitCode: 1, stdout: "", stderr: "Failed to encode JSON: \(error.localizedDescription)\n")
                }
            }
            return Result(exitCode: 0, stdout: formatDiagnostic(diagnostic, home: home), stderr: "")
        case let .scan(options):
            let report: ScanReport
            do {
                report = try await scan()
            } catch {
                return Result(exitCode: 1, stdout: "", stderr: "Scan failed: \(error.localizedDescription)\n")
            }
            let matched = ReviewFilter.candidates(
                report.candidates,
                query: options.query,
                risk: options.risk,
                category: options.category,
                sort: options.sort
            )
            let displayed = options.limit.map { Array(matched.prefix($0)) } ?? matched
            let available = freeSpace()
            if options.json {
                return encodeJSON(
                    displayed: displayed,
                    matched: matched,
                    totalScannedCount: report.candidates.count,
                    warnings: report.warnings,
                    freeSpaceBytes: available,
                    now: now,
                    version: version
                )
            }
            let table = formatTable(
                displayed: displayed,
                matched: matched,
                freeSpaceBytes: available,
                home: home
            )
            let warningText = report.warnings.isEmpty ? "" : report.warnings.map { "Warning: \($0)" }.joined(separator: "\n") + "\n"
            return Result(exitCode: 0, stdout: table, stderr: warningText)
        }
    }

    static func runSynchronously(_ command: Command) -> Result {
        let storage = OSAllocatedUnfairLock<Result?>(initialState: nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let result = await run(command)
            storage.withLock { $0 = result }
            semaphore.signal()
        }
        semaphore.wait()
        return storage.withLock { $0 } ?? Result(exitCode: 1, stdout: "", stderr: "Scan failed unexpectedly.\n")
    }

    static func writeAndExit(_ result: Result) -> Never {
        if !result.stdout.isEmpty { try? FileHandle.standardOutput.write(contentsOf: Data(result.stdout.utf8)) }
        if !result.stderr.isEmpty { try? FileHandle.standardError.write(contentsOf: Data(result.stderr.utf8)) }
        Darwin.exit(result.exitCode)
    }

    private static func encodeJSON(
        displayed: [CleanupCandidate],
        matched: [CleanupCandidate],
        totalScannedCount: Int,
        warnings: [String],
        freeSpaceBytes: Int64?,
        now: Date,
        version: String
    ) -> Result {
        let payload = ScanJSON(
            version: version,
            scannedAt: now,
            freeSpaceBytes: freeSpaceBytes,
            totalScannedCount: totalScannedCount,
            matchedCount: matched.count,
            matchedBytes: matched.reduce(0) { $0 + $1.size },
            warnings: warnings,
            candidates: displayed.map { item in
                ScanJSON.Item(
                    name: item.name,
                    path: item.url.path,
                    category: item.category.rawValue,
                    risk: riskKey(item.risk),
                    sizeBytes: item.size,
                    deletionMode: item.deletionMode.rawValue,
                    reason: item.reason
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(payload)
            return Result(exitCode: 0, stdout: String(decoding: data, as: UTF8.self) + "\n", stderr: "")
        } catch {
            return Result(exitCode: 1, stdout: "", stderr: "Failed to encode JSON: \(error.localizedDescription)\n")
        }
    }

    private static func formatTable(
        displayed: [CleanupCandidate],
        matched: [CleanupCandidate],
        freeSpaceBytes: Int64?,
        home: URL
    ) -> String {
        let homePrefix = CleanupPath.fileURL(home).path + "/"
        let freeSuffix = freeSpaceBytes.map { " · \($0.diskSize) free" } ?? ""
        guard !displayed.isEmpty else {
            return "No cleanup candidates found\(freeSuffix).\n"
        }
        let rows: [(size: String, risk: String, category: String, name: String, path: String)] = displayed.map { item in
            let displayPath = item.url.path.hasPrefix(homePrefix)
                ? "~/" + item.url.path.dropFirst(homePrefix.count)
                : item.url.path
            return (item.size.diskSize, item.risk.title, item.category.title, item.name, displayPath)
        }
        let sizeWidth = max(4, rows.map(\.size.count).max() ?? 4)
        let riskWidth = max(4, rows.map(\.risk.count).max() ?? 4)
        let catWidth = max(8, rows.map(\.category.count).max() ?? 8)
        let nameWidth = min(40, max(4, rows.map(\.name.count).max() ?? 4))

        var lines: [String] = []
        lines.append([
            pad("SIZE", width: sizeWidth),
            pad("RISK", width: riskWidth),
            pad("CATEGORY", width: catWidth),
            pad("NAME", width: nameWidth),
            "PATH"
        ].joined(separator: "  "))
        for row in rows {
            lines.append([
                pad(row.size, width: sizeWidth),
                pad(row.risk, width: riskWidth),
                pad(row.category, width: catWidth),
                pad(truncate(row.name, maxLength: nameWidth), width: nameWidth),
                row.path
            ].joined(separator: "  "))
        }
        let totalBytes = matched.reduce(Int64(0)) { $0 + $1.size }
        let countSummary = displayed.count == matched.count
            ? "\(matched.count) candidate(s)"
            : "Showing \(displayed.count) of \(matched.count) candidate(s)"
        lines.append("")
        lines.append("\(countSummary) · \(totalBytes.diskSize) reclaimable (estimate)\(freeSuffix)")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatDiagnostic(_ diagnostic: PathDiagnostic, home: URL) -> String {
        let homePrefix = CleanupPath.fileURL(home).path + "/"
        let displayPath = diagnostic.path.hasPrefix(homePrefix)
            ? "~/" + diagnostic.path.dropFirst(homePrefix.count)
            : diagnostic.path
        var lines = [
            "Path:     \(displayPath)",
            "Verdict:  \(diagnostic.verdict.title)",
            "Matcher:  \(diagnostic.matcher)",
        ]
        if let risk = diagnostic.risk { lines.append("Risk:     \(risk)") }
        if let size = diagnostic.sizeBytes { lines.append("Size:     \(size.diskSize)") }
        lines.append("Summary:  \(diagnostic.summary)")
        if !diagnostic.reasons.isEmpty {
            lines.append("Reasons:")
            for reason in diagnostic.reasons { lines.append("  - \(reason)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func riskKey(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }

    private static func pad(_ text: String, width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength, maxLength > 1 else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }
}
