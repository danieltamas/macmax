import Foundation

/// The small part of JSON Schema the tool catalog uses: type (or a list of types), enum, minimum, maximum,
/// properties, required, items and `additionalProperties: false`.
public enum AgentSchema {
    /// The problems found, empty when `value` fits `schema`.
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") -> [String] {
        var problems: [String] = []
        if let types = schema["type"] {
            let allowed: [String]
            switch types {
            case let .string(name): allowed = [name]
            case let .array(names): allowed = names.compactMap { if case let .string(name) = $0 { name } else { nil } }
            default: allowed = []
            }
            if !allowed.isEmpty, !allowed.contains(where: { matches(value, type: $0) }) {
                return ["\(path): expected \(allowed.joined(separator: " or "))"]
            }
        }
        if case let .array(options)? = schema["enum"], !options.contains(value) { problems.append("\(path): not one of the allowed values") }
        if let number = number(value) {
            if let minimum = schema["minimum"].flatMap(number(_:)), number < minimum { problems.append("\(path): below \(minimum)") }
            if let maximum = schema["maximum"].flatMap(number(_:)), number > maximum { problems.append("\(path): above \(maximum)") }
        }
        if case let .object(fields) = value {
            if case let .array(required)? = schema["required"] {
                for case let .string(name) in required where fields[name] == nil { problems.append("\(path): \(name) is required") }
            }
            let properties: [String: JSONValue]
            if case let .object(declared)? = schema["properties"] { properties = declared } else { properties = [:] }
            for (name, child) in fields.sorted(by: { $0.key < $1.key }) {
                if let childSchema = properties[name] {
                    problems += validate(child, against: childSchema, path: "\(path).\(name)")
                } else if schema["additionalProperties"] == .bool(false) {
                    problems.append("\(path): \(name) is not a known argument")
                }
            }
        }
        if case let .array(items) = value, let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() { problems += validate(item, against: itemSchema, path: "\(path)[\(index)]") }
        }
        return problems
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case let .int(number): Double(number)
        case let .double(number): number
        default: nil
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object), ("number", .int), ("number", .double),
             ("integer", .int): true
        case let ("integer", .double(number)): number == number.rounded() && abs(number) < 1e15
        default: false
        }
    }
}
