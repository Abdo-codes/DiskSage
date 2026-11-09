import Darwin
import Foundation

/// Items that the user told DiskSage to keep. A kept path is never offered or deleted, and neither is
/// a folder that contains it. A simulator whose name matches a pattern (such as `lane-*`) is never offered or deleted.
struct KeepRules: Sendable, Equatable {
    static let pathsKey = "keepPaths"
    static let simulatorNamesKey = "keepSimulatorNames"

    var paths: [String] = []
    var simulatorNames: [String] = []

    static func current(defaults: UserDefaults = .standard) -> Self {
        parse(paths: defaults.string(forKey: pathsKey) ?? "", simulatorNames: defaults.string(forKey: simulatorNamesKey) ?? "")
    }

    /// Paths: one per line, absolute or starting with `~/`. Simulator names: patterns, one per line or comma-separated.
    static func parse(paths: String, simulatorNames: String,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let home = CleanupPath.fileURL(home).path
        let kept = lines(paths, separators: "\n").compactMap { line -> String? in
            let expanded = line.hasPrefix("~/") ? home + line.dropFirst(1) : line
            guard expanded.hasPrefix("/"), expanded != "/" else { return nil }
            return CleanupPath.fileURL(URL(fileURLWithPath: expanded)).path
        }
        return Self(paths: kept, simulatorNames: lines(simulatorNames, separators: "\n,"))
    }

    /// Invalid lines, so Settings can reject them instead of ignoring them.
    static func invalidPaths(_ text: String) -> [String] {
        lines(text, separators: "\n").filter { !($0.hasPrefix("/") || $0.hasPrefix("~/")) || $0 == "/" }
    }

    /// True when the item is a kept path, is inside one, or contains one.
    /// Paths compare without case, because the default APFS volume ignores case.
    func keeps(_ url: URL) -> Bool {
        let path = Self.key(CleanupPath.fileURL(url).path)
        return paths.contains { kept in
            let kept = Self.key(kept)
            return path == kept || path.hasPrefix(kept + "/") || kept.hasPrefix(path + "/")
        }
    }

    func keepsSimulator(named name: String) -> Bool {
        simulatorNames.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }

    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    private static func lines(_ text: String, separators: String) -> [String] {
        text.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
