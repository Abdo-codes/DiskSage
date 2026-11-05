import Foundation

enum CleanupPath {
    /// Lexical normalization must not turn /private/tmp back into its /tmp symlink.
    /// Only macOS's fixed /tmp and /var aliases are expanded; user links stay intact
    /// so descriptor-relative traversal can reject them.
    static func fileURL(_ url: URL) -> URL {
        var parts: [String] = []
        for component in url.path.components(separatedBy: "/") {
            switch component {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        if parts.first == "tmp" || parts.first == "var" { parts.insert("private", at: 0) }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: true)
    }
}
