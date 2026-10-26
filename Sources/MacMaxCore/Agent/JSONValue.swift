import Foundation

/// A JSON document as a value: what the MCP server reads, validates and writes.
public enum JSONValue: Sendable, Equatable, Codable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// One line of JSON with sorted keys: the same value always gives the same bytes.
    public func line() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }

    /// Every string in the value passed through `transform`, keys included.
    func mapStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case let .string(value): .string(transform(value))
        case let .array(values): .array(values.map { $0.mapStrings(transform) })
        case let .object(fields): .object(Dictionary(fields.map { (transform($0.key), $0.value.mapStrings(transform)) },
                                                     uniquingKeysWith: { first, _ in first }))
        default: self
        }
    }
}
