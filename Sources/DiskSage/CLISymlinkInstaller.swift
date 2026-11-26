import Darwin
import Foundation

/// Installs or removes the user CLI convenience symlink at `~/.local/bin/disksage`
/// pointing to DiskSage's app executable so `disksage scan` and `disksage explain` work from Terminal.
enum CLISymlinkInstaller {
    enum Status: Equatable, Sendable {
        case installed(target: String)
        case notInstalled
        case pointsElsewhere(target: String, isDiskSage: Bool)
        case blockedByExistingFile
    }

    static func linkURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        CleanupPath.fileURL(home).appending(path: ".local/bin/disksage")
    }

    static func status(
        executableURL: URL? = Bundle.main.executableURL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Status {
        let link = linkURL(home: home)
        var info = stat()
        guard lstat(link.path, &info) == 0 else {
            return .notInstalled
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else {
            return .blockedByExistingFile
        }
        guard let rawDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return .pointsElsewhere(target: "", isDiskSage: false)
        }
        let binDirectory = link.deletingLastPathComponent()
        let resolvedDestination = resolvedSymlinkTarget(rawDestination, relativeTo: binDirectory)
        if let executableURL {
            let expected = executableURL.standardizedFileURL.resolvingSymlinksInPath()
            if resolvedDestination == expected {
                return .installed(target: rawDestination)
            }
        }
        return .pointsElsewhere(
            target: rawDestination,
            isDiskSage: isDiskSageTarget(rawDestination, relativeTo: binDirectory, executableURL: executableURL)
        )
    }

    @discardableResult
    static func install(
        executableURL: URL? = Bundle.main.executableURL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        replaceForeignSymlink: Bool = false
    ) throws -> URL {
        guard let executableURL else {
            throw FeatureFailure(message: "Could not locate DiskSage’s executable path.")
        }
        let target = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        var targetInfo = stat()
        guard stat(target.path, &targetInfo) == 0,
              (targetInfo.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: target.path) else {
            throw FeatureFailure(message: "DiskSage executable is missing or not executable at \(target.path).")
        }

        let link = linkURL(home: home)
        let binDirectory = link.deletingLastPathComponent()
        var dirInfo = stat()
        if stat(binDirectory.path, &dirInfo) == 0 {
            guard (dirInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw FeatureFailure(message: "\(binDirectory.path) exists and is not a directory.")
            }
        } else {
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        }

        var existingInfo = stat()
        if lstat(link.path, &existingInfo) == 0 {
            guard (existingInfo.st_mode & S_IFMT) == S_IFLNK else {
                throw FeatureFailure(message: "\(link.path) already exists and is not a symbolic link. Remove or move it first.")
            }
            let existingTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? ""
            guard replaceForeignSymlink || isDiskSageTarget(existingTarget, relativeTo: binDirectory, executableURL: executableURL) else {
                throw FeatureFailure(message: "\(link.path) already points to \(existingTarget). Remove it first if you want DiskSage to use that name.")
            }

            let temp = binDirectory.appending(path: ".disksage-\(UUID().uuidString).tmp")
            try FileManager.default.createSymbolicLink(atPath: temp.path, withDestinationPath: target.path)
            if Darwin.rename(temp.path, link.path) != 0 {
                let code = errno
                try? FileManager.default.removeItem(at: temp)
                throw FeatureFailure(message: "Could not update CLI symlink: \(String(cString: strerror(code))).")
            }
            return link
        } else if errno != ENOENT {
            throw FeatureFailure(message: "Could not inspect \(link.path): \(String(cString: strerror(errno))).")
        }

        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        return link
    }

    static func uninstall(
        executableURL: URL? = Bundle.main.executableURL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        removeForeignSymlink: Bool = false
    ) throws {
        let link = linkURL(home: home)
        var info = stat()
        guard lstat(link.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw FeatureFailure(message: "Could not inspect \(link.path): \(String(cString: strerror(errno))).")
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else {
            throw FeatureFailure(message: "Refused to remove \(link.path) because it is not a symbolic link.")
        }
        let existingTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? ""
        guard removeForeignSymlink
                || isDiskSageTarget(existingTarget, relativeTo: link.deletingLastPathComponent(), executableURL: executableURL) else {
            throw FeatureFailure(message: "Refused to remove \(link.path) because it points to \(existingTarget) rather than DiskSage.")
        }
        if Darwin.unlink(link.path) != 0 {
            throw FeatureFailure(message: "Could not remove CLI symlink: \(String(cString: strerror(errno))).")
        }
    }

    static func isDiskSageTarget(
        _ rawDestination: String,
        relativeTo directory: URL,
        executableURL: URL? = Bundle.main.executableURL
    ) -> Bool {
        if URL(fileURLWithPath: rawDestination).lastPathComponent.lowercased() == "disksage" {
            return true
        }
        if let executableURL {
            return resolvedSymlinkTarget(rawDestination, relativeTo: directory)
                == executableURL.standardizedFileURL.resolvingSymlinksInPath()
        }
        return false
    }

    static func isLocalBinOnPATH(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let bin = linkURL(home: home).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let raw = env["PATH"] ?? ""
        return raw.split(separator: ":").contains { entry in
            let expanded: String
            let str = String(entry)
            if str.hasPrefix("~/") {
                expanded = CleanupPath.fileURL(home).path + str.dropFirst(1)
            } else {
                expanded = str
            }
            let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
            return normalized == bin
        }
    }

    private static func resolvedSymlinkTarget(_ rawDestination: String, relativeTo directory: URL) -> URL {
        let url: URL
        if rawDestination.hasPrefix("/") {
            url = URL(fileURLWithPath: rawDestination)
        } else {
            url = URL(fileURLWithPath: rawDestination, relativeTo: directory)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
