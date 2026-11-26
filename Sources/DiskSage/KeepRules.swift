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

    static func displayPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let canonicalHome = CleanupPath.fileURL(home)
        let canonicalTarget = CleanupPath.fileURL(url)
        let homePath = canonicalHome.path
        if canonicalTarget.path.hasPrefix(homePath + "/") {
            return "~/" + canonicalTarget.path.dropFirst(homePath.count + 1)
        }
        return canonicalTarget.path
    }

    struct AppendResult: Equatable, Sendable {
        let text: String
        let added: [URL]
        let unsupported: [URL]
    }

    static func canRepresent(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let canonicalHome = CleanupPath.fileURL(home)
        let canonical = CleanupPath.fileURL(url).path
        guard !canonical.isEmpty, canonical != "/" else { return false }
        let formatted = displayPath(url, home: canonicalHome)
        guard !formatted.contains(where: \.isNewline),
              formatted.trimmingCharacters(in: .whitespaces) == formatted else {
            return false
        }
        return parse(paths: formatted, simulatorNames: "", home: canonicalHome).paths == [canonical]
    }

    static func append(urls: [URL], to existingText: String,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppendResult {
        let canonicalHome = CleanupPath.fileURL(home)
        var existingLines = lines(existingText, separators: "\n")
        var seenKeys = Set(existingLines.compactMap { line -> String? in
            let expanded = line.hasPrefix("~/") ? canonicalHome.path + line.dropFirst(1) : line
            guard expanded.hasPrefix("/"), expanded != "/" else { return nil }
            return Self.key(CleanupPath.fileURL(URL(fileURLWithPath: expanded)).path)
        })
        var added: [URL] = []
        var unsupported: [URL] = []
        for url in urls {
            guard canRepresent(url, home: canonicalHome) else {
                unsupported.append(url)
                continue
            }
            let canonical = CleanupPath.fileURL(url).path
            let k = Self.key(canonical)
            guard seenKeys.insert(k).inserted else { continue }
            existingLines.append(displayPath(url, home: canonicalHome))
            added.append(url)
        }
        return AppendResult(text: existingLines.joined(separator: "\n"), added: added, unsupported: unsupported)
    }

    static func appending(urls: [URL], to existingText: String,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        append(urls: urls, to: existingText, home: home).text
    }

    @discardableResult
    static func keep(_ urls: [URL], defaults: UserDefaults = .standard,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppendResult {
        let existing = defaults.string(forKey: pathsKey) ?? ""
        let result = append(urls: urls, to: existing, home: home)
        guard !result.added.isEmpty, result.text != existing else { return result }
        defaults.set(result.text, forKey: pathsKey)
        NotificationCenter.default.post(name: .diskSageSettingsChanged, object: nil)
        return result
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
