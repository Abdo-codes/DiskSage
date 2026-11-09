import Foundation

/// One simulator device as `xcrun simctl list devices -j` reports it.
struct SimulatorDevice: Equatable, Sendable {
    let udid: String
    let name: String
    let state: String
    let runtime: String
    let isAvailable: Bool

    var isShutdown: Bool { state == "Shutdown" }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" becomes "iOS 27.0".
    var runtimeTitle: String {
        guard let last = runtime.split(separator: ".").last else { return runtime }
        let parts = last.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return String(last) }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    static func isUDID(_ text: String) -> Bool {
        UUID(uuidString: text)?.uuidString == text.uppercased() && text.count == 36
    }

    /// simctl writes warnings to the same stream, so the JSON starts at the first brace.
    static func parse(_ data: Data) throws -> [SimulatorDevice] {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else {
            throw FeatureFailure(message: "The simulator list could not be read. Nothing was deleted.")
        }
        struct Entry: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
        }
        struct List: Decodable { let devices: [String: [Entry]] }
        let list = try JSONDecoder().decode(List.self, from: data[start...])
        return list.devices.flatMap { runtime, entries in
            entries.filter { isUDID($0.udid) }.map {
                SimulatorDevice(udid: $0.udid.uppercased(), name: $0.name, state: $0.state,
                                runtime: runtime, isAvailable: $0.isAvailable ?? true)
            }
        }.sorted { $0.udid < $1.udid }
    }
}
