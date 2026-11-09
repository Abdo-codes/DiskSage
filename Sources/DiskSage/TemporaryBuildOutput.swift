import Darwin
import Foundation

/// Xcode output and agent scratch folders that builds leave in temporary folders.
/// DiskSage offers each one as a whole folder, because the parts that the
/// generated-file rule keeps (SourcePackages, app bundles, logs) are most of its size.
enum TemporaryBuildOutput {
    enum Kind: String, Sendable {
        /// A custom `-derivedDataPath` folder, found by its layout.
        case derivedData
        /// A loose `.xcresult` bundle.
        case resultBundle
        /// A loose built `.app` bundle.
        case appBundle
        /// A Claude Code session scratchpad.
        case scratchpad
    }

    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400
    static let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    static var claudeRoot: URL { temporaryRoot.appending(path: "claude-\(getuid())", directoryHint: .isDirectory) }

    /// Roots where a DerivedData-shaped folder is offered as a whole folder.
    static func derivedDataRoots(home: URL) -> [URL] {
        [temporaryRoot, CleanupPath.fileURL(home).appending(path: "Documents/Codex", directoryHint: .isDirectory)]
    }

    /// The kind of a folder from its path and layout. Age and activity are checked separately.
    static func kind(of url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Kind? {
        let url = CleanupPath.fileURL(url)
        guard isRealDirectory(url) else { return nil }
        let claude = claudeRoot.pathComponents
        if url.pathComponents.starts(with: claude) {
            let rest = url.pathComponents.dropFirst(claude.count)
            if rest.count == 3, rest.last == "scratchpad" { return .scratchpad }
        } else if url.pathComponents.starts(with: temporaryRoot.pathComponents) {
            // Loose bundles: a direct child of /private/tmp, or of one folder in it.
            let depth = url.pathComponents.count - temporaryRoot.pathComponents.count
            let name = url.lastPathComponent.lowercased()
            if (1...2).contains(depth) {
                if name.hasSuffix(".xcresult"), isRegularFile(url.appending(path: "Info.plist")) { return .resultBundle }
                if name.hasSuffix(".app"), isRegularFile(url.appending(path: "Contents/Info.plist")) ||
                    isRegularFile(url.appending(path: "Info.plist")) { return .appBundle }
            }
        }
        let inRoot = derivedDataRoots(home: home).contains { url.pathComponents.count > $0.pathComponents.count &&
            url.pathComponents.starts(with: CleanupPath.fileURL($0).pathComponents) }
        return inRoot && hasDerivedDataLayout(url) ? .derivedData : nil
    }

    /// `xcodebuild -derivedDataPath` writes `info.plist` and `Build/`, plus caches and logs.
    static func hasDerivedDataLayout(_ url: URL) -> Bool {
        guard isRegularFile(url.appending(path: "info.plist")), isRealDirectory(url.appending(path: "Build")) else { return false }
        return ["Logs", "ModuleCache.noindex", "Index.noindex"].contains { isRealDirectory(url.appending(path: $0)) } ||
            exists(url.appending(path: "SourcePackages"))
    }

    /// The risk for a folder with no change for `idle` seconds, or nil while it is too new to offer.
    static func risk(_ kind: Kind, idle: TimeInterval) -> RiskLevel? {
        switch kind {
        case .derivedData: idle >= day ? .low : (idle >= 6 * hour ? .medium : nil)
        case .resultBundle, .appBundle: idle >= day ? .medium : nil
        // Session notes and results can matter to a resumed session: review only, never automatic.
        case .scratchpad: idle >= 3 * day ? .medium : nil
        }
    }

    static func category(_ kind: Kind) -> CandidateCategory { kind == .scratchpad ? .cache : .build }

    static func reason(_ kind: Kind, idle: TimeInterval) -> String {
        let age = idle >= 2 * day ? "\(Int(idle / day)) days" : "\(Int(idle / hour)) hours"
        switch kind {
        case .derivedData:
            return "Xcode build folder with no changes for \(age) and no running process. The whole folder is deleted; Xcode builds it again."
        case .resultBundle:
            return "Test result bundle in a temporary folder with no changes for \(age). Keep it if you still need its results."
        case .appBundle:
            return "Built app in a temporary folder with no changes for \(age). It is not running."
        case .scratchpad:
            return "Claude session scratchpad with no changes for \(age). Review it first: it can hold notes or results."
        }
    }

    private static func info(_ url: URL) -> stat? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value : nil
    }
    private static func exists(_ url: URL) -> Bool { info(url) != nil }
    private static func isRegularFile(_ url: URL) -> Bool { info(url).map { $0.st_mode & S_IFMT == S_IFREG } ?? false }
    static func isRealDirectory(_ url: URL) -> Bool {
        guard let value = info(url) else { return false }
        return value.st_mode & S_IFMT == S_IFDIR && value.st_uid == getuid()
    }
}
