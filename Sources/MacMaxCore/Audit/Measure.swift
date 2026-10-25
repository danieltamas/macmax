import Foundation

/// A `Reading` reduced to what an audit stores and compares: the value or why there is none.
/// `unavailable` means this Mac does not have it (a rule passes as not applicable); `failed` means it should
/// have been readable and was not (a rule reports unknown). Neither is ever treated as a value.
public enum Measure<Value: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    case ok(Value)
    case unavailable(String)
    case failed(String)

    public init(_ reading: Reading<Value>) {
        switch reading {
        case let .ok(value, _, _): self = .ok(value)
        case let .unavailable(reason): self = .unavailable(reason)
        case let .failed(reason): self = .failed(reason)
        }
    }

    public var value: Value? {
        if case let .ok(value) = self { return value }
        return nil
    }
}

/// A named number: a container's CPU, a daemon's resident memory.
public struct NamedValue: Sendable, Codable, Equatable {
    public let name: String
    public let value: Double

    public init(name: String, value: Double) {
        self.name = name
        self.value = value
    }
}
