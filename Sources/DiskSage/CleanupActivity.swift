import Foundation
import Darwin

struct CleanupActivity: Sendable {
    var paths: Set<String>
    var commands: Set<String> = []
    static let idle = Self(paths: [])

    static func capture() throws -> Self {
        let output = try WorktreeGitProcess().execute("/usr/sbin/lsof", ["-nP", "-F0pcn"])
        guard output.code == 0 else { throw FeatureFailure(message: "Active files could not be checked. Nothing was deleted.") }
        var pid: Int32?, paths = Set<String>(), commands = Set<String>()
        for raw in output.data.split(separator: 0) {
            let field = raw.drop(while: { $0 == 10 || $0 == 13 })
            guard let first = field.first else { continue }
            if first == 112 { pid = Int32(String(decoding: field.dropFirst(), as: UTF8.self)) }
            guard pid != getpid() else { continue }
            if first == 99 { commands.insert(String(decoding: field.dropFirst(), as: UTF8.self)) }
            if first == 110, field.dropFirst().first == 47 {
                let decoded = try WorktreeActivity.paths(Data(field) + Data([0]))
                paths.formUnion(decoded.map { CleanupPath.fileURL(URL(fileURLWithPath: $0)).path })
            }
        }
        guard !paths.isEmpty else { throw FeatureFailure(message: "Process activity was unavailable. Nothing was deleted.") }
        return Self(paths: paths, commands: commands)
    }

    func contains(_ root: URL, rule: GeneratedCleanupRule? = nil) -> Bool {
        let path = CleanupPath.fileURL(root).path
        if paths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { return true }
        if rule == .goBuild || rule == .goDownloads {
            return !commands.isDisjoint(with: ["go", "compile", "link", "gopls"])
        }
        return false
    }

    func requireIdle(_ root: URL, rule: GeneratedCleanupRule? = nil) throws {
        guard !contains(root, rule: rule) else {
            throw FeatureFailure(message: "The folder is in use. Close its apps or builds and scan again.")
        }
    }
}
