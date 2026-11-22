import Darwin
import Foundation

/// Rules matching disposable per-project cache directories (such as `node_modules`, `target`, `.venv`,
/// `.next`, `build`, `dist`, and `_build`). Every matched directory must still pass Git-ignored,
/// zero-tracked-files, nested-repo, running-process, and quiet-project checks before it is offered.
struct ProjectCacheRules: Sendable, Equatable {
    struct Match: Sendable, Equatable {
        /// Rule key from `names` (for example `"target"` or `"vendor/bundle"`).
        let key: String
        /// Human-readable rule label (for example `"target beside Cargo.toml"`).
        let label: String
        /// Protected relative patterns inside the matched directory.
        let refuseInside: [String]
    }

    var names: [String]
    var beside: [String: [String]]
    var refuseInside: [String: [String]]
    var skip: Set<String>
    var quietHours: Double

    static let forbiddenVCSNames: Set<String> = [".git", ".hg", ".jj", ".svn"]

    /// Built-in multi-ecosystem rules. `.build` and `DerivedData` are left to DiskSage's
    /// dedicated Swift/Xcode generated-file and whole-folder rules to avoid overlap.
    static let `default` = ProjectCacheRules(
        names: [
            ".astro", ".gradle", ".mypy_cache", ".next", ".nox",
            ".parcel-cache", ".pytest_cache", ".ruff_cache", ".svelte-kit", ".tox",
            ".turbo", ".venv", ".zig-cache", "__pycache__", "_build",
            "bin", "build", "dist", "node_modules", "obj", "target",
            "tmp/cache", "vendor/bundle", "venv", "zig-cache",
        ],
        beside: [
            ".zig-cache": ["build.zig"],
            "_build": ["mix.exs"],
            "bin": ["*.csproj", "*.fsproj", "*.vbproj"],
            "build": ["build.gradle", "build.gradle.kts", "pyproject.toml",
                      "settings.gradle", "settings.gradle.kts", "setup.py"],
            "dist": ["package.json", "pyproject.toml", "setup.py"],
            "obj": ["*.csproj", "*.fsproj", "*.vbproj"],
            "target": ["Cargo.toml", "pom.xml"],
            "tmp/cache": ["config.ru"],
            "vendor/bundle": ["Gemfile", "gems.rb"],
            "venv": ["pyproject.toml", "requirements.txt", "setup.py"],
            "zig-cache": ["build.zig"],
        ],
        refuseInside: [
            // Mix releases hold generated Erlang cookies/versions; Rebar3 keeps dependency sources in _build/*/lib/*/src.
            "_build": ["*/rel", "*/lib/*/src"],
        ],
        skip: [".cache", ".git", ".hg", ".jj", ".svn", ".build", "DerivedData"],
        quietHours: 24
    )

    /// Matches a directory path relative to a project root (slash-separated, no leading slash).
    func match(relativePath: String, hasMarker: (_ holderRelativeDir: String, _ marker: String) -> Bool) -> Match? {
        for name in names {
            guard let holder = Self.holderDirectory(relativePath: relativePath, ruleName: name) else { continue }
            guard let markers = beside[name] else {
                return Match(key: name, label: name, refuseInside: refuseInside[name] ?? [])
            }
            for marker in markers where hasMarker(holder, marker) {
                return Match(key: name, label: "\(name) beside \(marker)", refuseInside: refuseInside[name] ?? [])
            }
        }
        return nil
    }

    /// Matches a concrete directory URL directly against its parent/ancestor on disk.
    func matchDirectory(_ directory: URL, under root: URL) -> Match? {
        let dir = CleanupPath.fileURL(directory)
        let base = CleanupPath.fileURL(root)
        guard dir.path.hasPrefix(base.path + "/") else { return nil }
        let relative = String(dir.path.dropFirst(base.path.count + 1))
        guard !relative.split(separator: "/").contains(where: { skip.contains(String($0)) }) else { return nil }
        return match(relativePath: relative) { holderRel, marker in
            let holderURL = holderRel.isEmpty ? base : base.appending(path: holderRel, directoryHint: .isDirectory)
            return Self.directoryHasEntry(holderURL, matching: marker)
        }
    }

    /// Returns the path of the first protected entry matching `patterns` inside `directory`,
    /// or nil when none exist. Throws if a traversed directory cannot be read (fails closed).
    static func refuseInsideViolation(in directory: URL, patterns: [String]) throws -> String? {
        for pattern in patterns {
            let elements = pattern.split(separator: "/").map(String.init)
            guard !elements.isEmpty else { continue }
            if let hit = try matchInside(directory: directory, elements: elements) {
                return "\(hit) (protected by \(pattern))"
            }
        }
        return nil
    }

    static func directoryHasEntry(_ directory: URL, matching marker: String) -> Bool {
        if !isPattern(marker) {
            var info = stat()
            return lstat(directory.appending(path: marker).path, &info) == 0
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return entries.contains { fnmatch(marker, $0, 0) == 0 }
    }

    static func isValidRuleName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("\\"), !name.hasPrefix("/"), !name.hasSuffix("/") else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !forbiddenVCSNames.contains(part.lowercased())
        }
    }

    static func isValidInsidePattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, !pattern.contains("\\") else { return false }
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isPattern(_ value: String) -> Bool {
        value.contains(where: { "*?[\\".contains($0) })
    }

    private static func holderDirectory(relativePath: String, ruleName: String) -> String? {
        if relativePath == ruleName { return "" }
        let suffix = "/" + ruleName
        guard relativePath.hasSuffix(suffix) else { return nil }
        let prefix = String(relativePath.dropLast(suffix.count))
        return prefix.isEmpty ? nil : prefix
    }

    private static func matchInside(directory: URL, elements: [String]) throws -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            throw FeatureFailure(message: "Could not read \(directory.lastPathComponent) to verify protected entries.")
        }
        let head = elements[0]
        for entry in entries.sorted() {
            guard fnmatch(head, entry, 0) == 0 else { continue }
            if elements.count == 1 { return entry }
            let child = directory.appending(path: entry)
            var info = stat()
            guard lstat(child.path, &info) == 0 else {
                throw FeatureFailure(message: "Could not inspect \(child.path) to verify protected entries.")
            }
            // Never follow symlinks when descending into protected-entry checks.
            guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            if let rest = try matchInside(directory: child, elements: Array(elements.dropFirst())) {
                return "\(entry)/\(rest)"
            }
        }
        return nil
    }
}
