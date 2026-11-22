import Darwin
import Foundation

/// Inspects an Xcode DerivedData project's `info.plist` to determine whether its
/// referenced workspace still exists on disk.
enum XcodeWorkspaceStatus: Equatable, Sendable {
    case present(String)
    case missing(String)
    case unknown

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }

    static func check(derivedDataFolder: URL) -> Self {
        let plist = CleanupPath.fileURL(derivedDataFolder).appending(path: "info.plist")
        guard let path = workspacePath(from: plist) else { return .unknown }
        // A workspace on a volume that is not currently mounted may still exist.
        if path.hasPrefix("/Volumes/") {
            let rest = path.dropFirst("/Volumes/".count)
            let volumeName = rest.prefix(while: { $0 != "/" })
            guard !volumeName.isEmpty else { return .unknown }
            var volumeInfo = stat()
            guard lstat("/Volumes/\(volumeName)", &volumeInfo) == 0 else { return .unknown }
        }
        var info = stat()
        if lstat(path, &info) == 0 { return .present(path) }
        return errno == ENOENT ? .missing(path) : .unknown
    }

    static func workspacePath(from plistURL: URL) -> String? {
        var info = stat()
        guard lstat(plistURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 1_048_576,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = plist["WorkspacePath"] as? String,
              path.hasPrefix("/") else { return nil }
        return path
    }
}
