import Foundation

/// Every collected value has three outcomes, never a silent zero: present, absent on this Mac,
/// or should have been there and could not be read. Rules and actions treat the last two as
/// unknown (LESSONS.md section 9, class 1).
public enum Reading<Value: Sendable>: Sendable {
    case ok(Value, source: String, at: Date)
    /// This Mac does not have it: no battery, no GPU counter.
    case unavailable(reason: String)
    /// It should be there and could not be read or parsed.
    case failed(reason: String)

    public var value: Value? {
        if case let .ok(value, _, _) = self { return value }
        return nil
    }

    public var isOK: Bool { value != nil }

    /// The reason a reading is not ok, for display and logs.
    public var problem: String? {
        switch self {
        case .ok: nil
        case let .unavailable(reason), let .failed(reason): reason
        }
    }

    /// The same outcome with the value changed; a non-ok reading stays as it is.
    public func map<T: Sendable>(_ transform: (Value) -> T) -> Reading<T> {
        switch self {
        case let .ok(value, source, at): .ok(transform(value), source: source, at: at)
        case let .unavailable(reason): .unavailable(reason: reason)
        case let .failed(reason): .failed(reason: reason)
        }
    }
}

extension Reading: Equatable where Value: Equatable {}
