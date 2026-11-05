import Foundation

indirect enum ToolValue: Codable, Equatable, Sendable {
    case string(String), integer(Int), number(Double), bool(Bool), array([Self]), object([String: Self]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([Self].self) { self = .array(result) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(item): try value.encode(item)
        case let .integer(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .bool(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var integer: Int? { if case let .integer(value) = self { value } else { nil } }
    var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
    var object: [String: Self]? { if case let .object(value) = self { value } else { nil } }
    var array: [Self]? { if case let .array(value) = self { value } else { nil } }
    var display: String {
        switch self {
        case let .string(value): value
        case let .bool(value): value ? "On" : "Off"
        case let .integer(value): String(value)
        default: String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
        }
    }
    static func encode<Value: Encodable>(_ value: Value) throws -> Self {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }
}

struct ManagementApproval: Equatable, Sendable, Identifiable {
    let id: UUID
    let request: AgentToolRequest
    let title: String
    let details: String
    var schedule: CleanupSchedule?
    var previousSchedule: CleanupSchedule?
    var previousSettings: [String: ToolValue]?
    var configuration: AgentConfiguration?
}

struct ToolMutationReceipt: Codable, Equatable, Sendable {
    let request: AgentToolRequest
    let result: ToolValue
    let timestamp: Date
}
