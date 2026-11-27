import Darwin
import Foundation
import Testing
@testable import DiskSage

struct CLISymlinkInstallerTests {
    @Test func installsUpdatesUninstallsAndProtectsForeignOrNonSymlinkFiles() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let bin = try f.folder("bin")
        let binaryA = bin.appending(path: "DiskSage")
        let binaryB = try f.folder("alt").appending(path: "DiskSage")
        let foreignTarget = try f.folder("foreign").appending(path: "other-tool")
        for file in [binaryA, binaryB, foreignTarget] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            #expect(Darwin.chmod(file.path, 0o755) == 0)
        }

        // Initially not installed.
        #expect(CLISymlinkInstaller.status(executableURL: binaryA, home: f.base) == .notInstalled)
        let installedLink = try CLISymlinkInstaller.install(executableURL: binaryA, home: f.base)
        #expect(installedLink == CLISymlinkInstaller.linkURL(home: f.base))
        #expect(CLISymlinkInstaller.status(executableURL: binaryA, home: f.base) == .installed(target: binaryA.standardizedFileURL.resolvingSymlinksInPath().path))

        // Older DiskSage symlink is detected as pointsElsewhere (isDiskSage: true) and updated cleanly.
        #expect(CLISymlinkInstaller.status(executableURL: binaryB, home: f.base)
                == .pointsElsewhere(target: binaryA.standardizedFileURL.resolvingSymlinksInPath().path, isDiskSage: true))
        _ = try CLISymlinkInstaller.install(executableURL: binaryB, home: f.base)
        #expect(CLISymlinkInstaller.status(executableURL: binaryB, home: f.base) == .installed(target: binaryB.standardizedFileURL.resolvingSymlinksInPath().path))

        // Uninstall removes the symlink.
        try CLISymlinkInstaller.uninstall(executableURL: binaryB, home: f.base)
        #expect(CLISymlinkInstaller.status(executableURL: binaryB, home: f.base) == .notInstalled)

        // Foreign symlink is refused by default on both install and uninstall, preserved, and replaceable when opted in.
        try FileManager.default.createSymbolicLink(atPath: installedLink.path, withDestinationPath: foreignTarget.path)
        #expect(CLISymlinkInstaller.status(executableURL: binaryA, home: f.base)
                == .pointsElsewhere(target: foreignTarget.path, isDiskSage: false))
        #expect(throws: (any Error).self) {
            _ = try CLISymlinkInstaller.install(executableURL: binaryA, home: f.base)
        }
        #expect(throws: (any Error).self) {
            try CLISymlinkInstaller.uninstall(executableURL: binaryA, home: f.base)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installedLink.path) == foreignTarget.path)
        _ = try CLISymlinkInstaller.install(executableURL: binaryA, home: f.base, replaceForeignSymlink: true)
        #expect(CLISymlinkInstaller.status(executableURL: binaryA, home: f.base) == .installed(target: binaryA.standardizedFileURL.resolvingSymlinksInPath().path))

        // Non-symlink regular file blocks both install and uninstall.
        try FileManager.default.removeItem(at: installedLink)
        try Data("custom-script".utf8).write(to: installedLink)
        #expect(CLISymlinkInstaller.status(executableURL: binaryA, home: f.base) == .blockedByExistingFile)
        #expect(throws: (any Error).self) {
            _ = try CLISymlinkInstaller.install(executableURL: binaryA, home: f.base, replaceForeignSymlink: true)
        }
        #expect(throws: (any Error).self) {
            try CLISymlinkInstaller.uninstall(executableURL: binaryA, home: f.base, removeForeignSymlink: true)
        }
        #expect(try String(contentsOf: installedLink, encoding: .utf8) == "custom-script")

        // PATH helper matches ~/.local/bin accurately.
        let localBin = f.base.appending(path: ".local/bin").path
        #expect(CLISymlinkInstaller.isLocalBinOnPATH(env: ["PATH": "/usr/bin:~/.local/bin"], home: f.base))
        #expect(CLISymlinkInstaller.isLocalBinOnPATH(env: ["PATH": "/usr/bin:\(localBin)"], home: f.base))
        #expect(!CLISymlinkInstaller.isLocalBinOnPATH(env: ["PATH": "/usr/bin:/usr/local/bin"], home: f.base))
    }

    @Test func handlesRelativeSymlinksDanglingDiskSageSymlinksAndSymlinkedBinParent() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let realBinParent = try f.folder("real-bin")
        let localDir = try f.folder(".local")
        let localBin = localDir.appending(path: "bin")
        try FileManager.default.createSymbolicLink(at: localBin, withDestinationURL: realBinParent)

        let appBin = try f.folder("app").appending(path: "DiskSage")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: appBin)
        #expect(Darwin.chmod(appBin.path, 0o755) == 0)

        let link = CLISymlinkInstaller.linkURL(home: f.base)
        // Relative symlink pointing to DiskSage is recognized as installed.
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../app/DiskSage")
        #expect(CLISymlinkInstaller.status(executableURL: appBin, home: f.base) == .installed(target: "../app/DiskSage"))

        // Dangling symlink whose leaf is DiskSage is recognized as pointsElsewhere(isDiskSage: true) and safely replaced.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/old/DiskSage")
        #expect(CLISymlinkInstaller.status(executableURL: appBin, home: f.base)
                == .pointsElsewhere(target: "/nonexistent/old/DiskSage", isDiskSage: true))
        _ = try CLISymlinkInstaller.install(executableURL: appBin, home: f.base)
        #expect(CLISymlinkInstaller.status(executableURL: appBin, home: f.base)
                == .installed(target: appBin.standardizedFileURL.resolvingSymlinksInPath().path))
    }
}
