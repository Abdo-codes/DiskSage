import Foundation

/// A folder of device symbols that Xcode copies when a device connects:
/// `~/Library/Developer/Xcode/<platform> DeviceSupport/<model> <version> (<build>)[ <architecture>]`.
/// Older Xcode versions leave out the model.
struct DeviceSupportVersion: Equatable, Sendable {
    /// Empty when the name has no model.
    let model: String
    let version: [Int]
    let build: String
    let architecture: String

    static let platforms = ["iOS", "watchOS", "tvOS", "visionOS", "xrOS"]

    static func roots(home: URL) -> [URL] {
        platforms.map {
            CleanupPath.fileURL(home).appending(path: "Library/Developer/Xcode/\($0) DeviceSupport", directoryHint: .isDirectory)
        }
    }

    init?(name: String) {
        let parts = name.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let open = parts.firstIndex(where: { $0.count > 2 && $0.hasPrefix("(") && $0.hasSuffix(")") }),
              (1...2).contains(open), parts.count - open <= 2 else { return nil }
        let build = String(parts[open].dropFirst().dropLast())
        let numbers = parts[open - 1].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard build.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              (1...4).contains(numbers.count), numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.build = build
        version = numbers.compactMap { $0 }
        model = open == 2 ? parts[0] : ""
        architecture = open + 1 < parts.count ? parts[open + 1] : ""
        guard !model.contains("("), !architecture.isEmpty || open + 1 == parts.count else { return nil }
    }

    /// Versions compare number by number; a missing number counts as zero. Builds of one version are not ordered.
    func isNewer(than other: Self) -> Bool {
        let count = max(version.count, other.version.count)
        func padded(_ value: [Int]) -> [Int] { value + Array(repeating: 0, count: count - value.count) }
        return padded(other.version).lexicographicallyPrecedes(padded(version))
    }

    /// True when a sibling folder holds a newer version for the same device model and architecture.
    /// A folder without a model (from an older Xcode) is replaced by any newer version.
    static func isSuperseded(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        guard let own = DeviceSupportVersion(name: url.lastPathComponent),
              let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return false }
        return names.contains { name in
            guard let other = DeviceSupportVersion(name: name), other.architecture == own.architecture,
                  own.model.isEmpty || other.model == own.model, other.isNewer(than: own) else { return false }
            return TemporaryBuildOutput.isRealDirectory(parent.appending(path: name, directoryHint: .isDirectory))
        }
    }
}
