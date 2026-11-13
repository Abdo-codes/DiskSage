import Darwin
import Foundation

enum GeneratedCleanupRule: String, Codable, Hashable, Sendable {
    case buildArtifacts, browserCache, npmContent, goBuild, goDownloads, swiftPMArchives, bazelArchives
}

struct GeneratedCleanupSnapshot: Codable, Hashable, Sendable {
    let rule: GeneratedCleanupRule
    let cutoff: Date
    let digest: String
    let fileCount: Int
    /// True when the scan also offered idle DerivedData projects as whole folders, so their files were left out.
    /// Deletion reads the inventory the same way. Missing in older snapshots, which means false.
    var handsOffWholeFolders: Bool? = nil
    /// Sorted 8-byte fingerprints of the scanned files. With them, a deletion removes only the files that did not change.
    /// Missing in older snapshots, which means the whole folder must match the scan.
    var entryFingerprints: Data? = nil

    /// The fingerprints as a set, or nil when the snapshot has none or they do not match `fileCount`.
    var knownEntries: Set<UInt64>? {
        guard let entryFingerprints, entryFingerprints.count == fileCount * MemoryLayout<UInt64>.size else { return nil }
        return entryFingerprints.withUnsafeBytes { raw in
            Set((0..<fileCount).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self) })
        }
    }
}

enum GeneratedCleanupPolicy {
    static let minimumAge: TimeInterval = 3_600
    static let buildNames: Set<String> = [".build", "build", "DerivedData", "derived-data", "derived", "out"]
    static let compilerCaches: Set<String> = ["ModuleCache.noindex", "SDKExplicitPrecompiledModules",
        "ExplicitPrecompiledModules", "SwiftExplicitPrecompiledModules", "CompilationCache.noindex",
        "SDKStatCaches.noindex", "SymbolCache.noindex", "Index.noindex"]
    static let protectedNames: Set<String> = [".git", "source", "sources", "checkouts", "repositories",
        "sourcepackages", "prebuilts", "artifacts", "node_modules", "vendor", "_deps", "downloads", "plugins", "fixtures", "logs", "testlogs",
        "test-results", "testresults", "evidence", "screenshots", "baselines", "outputs", "preserved-ignored",
        "sessions", "local-agent-mode-sessions", "vm_bundles", "coresimulator", "simulator devices",
        "simulator%20devices", "ios devicesupport", "previews", "archives", "sessiondata.img", "indexeddb", "service worker", "local storage"]
    static let protectedExtensions: Set<String> = ["swift", "swiftinterface", "c", "cc", "cpp", "h", "hpp",
        "m", "mm", "py", "rb", "js", "ts", "kt", "metal", "md", "json", "txt", "log", "dia", "png",
        "jpg", "jpeg", "mp4", "mov", "profraw", "profdata", "xcactivitylog", "trace", "pftrace", "db", "sqlite"]
    static let compiledExtensions: Set<String> = ["pcm", "pch", "o", "a", "dylib", "so", "swiftmodule",
        "swiftdoc", "swiftsourceinfo", "swiftdeps", "bc", "air", "metallib", "sdkstatcache"]

    static func protected(_ name: String) -> Bool {
        let value = name.lowercased()
        return protectedNames.contains(value) || value.contains("snapshot") || value.contains("evidence") ||
            [".xcresult", ".xcarchive", ".dsym", ".app", ".simruntime"].contains(where: value.hasSuffix)
    }

    /// A tool can hold a lock file, so never offer one. Whole-word match: "lock.o" stays out, "Block.o" does not.
    static func isLockFile(_ name: String) -> Bool {
        let value = name.lowercased()
        if value.contains("lockfile") { return true }
        let words = value.split { !$0.isLetter }
        return words.contains { $0 == "lock" || $0 == "lck" }
    }

    static func mayDescend(_ parts: [String]) -> Bool {
        guard !parts.contains(where: protected) else { return false }
        // Downloaded external repositories are inputs, whereas bazel-out/.../external contains outputs.
        if parts.contains("external") && !parts.contains("bazel-out") { return false }
        return !parts.contains("sandbox") && !parts.contains("server") && !parts.contains("bazel-workers")
    }

    static func eligible(name: String, parents: [String], rootName: String,
                         rule: GeneratedCleanupRule, prefix: () throws -> Data,
                         checksum: () throws -> String) throws -> Bool {
        guard !protected(name), !parents.contains(where: protected), !isLockFile(name) else { return false }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch rule {
        case .goBuild:
            guard name.range(of: "^[0-9a-f]{64}-d$", options: .regularExpression) != nil else { return false }
            let bytes = try prefix()
            return [Data("!<arch>\n".utf8), Data("go object ".utf8), Data("go index v2".utf8), Data([0x7f, 0x45, 0x4c, 0x46]),
                    Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]),
                    Data([0xce, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xce])].contains { bytes.starts(with: $0) }
        case .goDownloads:
            return ["zip", "mod", "info", "ziphash"].contains(ext) || ["list", "latest"].contains(name)
        case .swiftPMArchives:
            return (name.hasPrefix("https_") || name.hasPrefix("http_")) && name.hasSuffix("_zip")
        case .bazelArchives:
            guard name == "file", parents.count == 1,
                  parents[0].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return false }
            return try checksum() == parents[0]
        case .npmContent:
            return parents.first == "content-v2" && parents.count >= 4
        case .browserCache:
            return ext.isEmpty || ["bin", "data", "cache", "vsix", "zip", "wasm"].contains(ext)
        case .buildArtifacts:
            guard !protectedExtensions.contains(ext) else { return false }
            let context = [rootName] + parents
            if context.contains("Index.noindex") || context.contains("CompilationCache.noindex") { return true }
            let buildContext = context.contains(where: compilerCaches.contains) || parents.contains("bazel-out") ||
                (parents.contains("Build") && (parents.contains("Intermediates.noindex") || parents.contains("Products"))) ||
                ((rootName == ".build" || rootName.hasPrefix(".build-")) &&
                 parents.contains(where: { ["debug", "release", "Debug", "Release"].contains($0) }))
            return buildContext && compiledExtensions.contains(ext)
        }
    }
}
