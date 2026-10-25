import Foundation

/// Turns cumulative per-process counters into per-interval bytes.
public struct NetworkDeltaTracker: Sendable {
    private var previous: [ProcessIdentity: NetworkCounters] = [:]
    private var previousTickMicroseconds: Int64?

    public init() {}

    /// `tickMicroseconds` is the wall-clock time of this reading in microseconds since the epoch; it
    /// is compared with process start times only, never used for a rate. A process that started after
    /// the previous tick counts from zero at its first reading; one that started earlier has traffic
    /// from before MacMax looked, so its first interval is unavailable.
    public mutating func update(_ current: [ProcessIdentity: NetworkCounters],
                                tickMicroseconds: Int64) -> [ProcessIdentity: Reading<NetworkCounters>] {
        let at = Date()
        defer {
            previous = current
            previousTickMicroseconds = tickMicroseconds
        }
        guard let lastTick = previousTickMicroseconds else {
            return current.mapValues { _ in .unavailable(reason: "needs a second reading to compute an interval") }
        }
        return current.reduce(into: [:]) { result, entry in
            let (identity, counters) = entry
            guard let before = previous[identity] else {
                result[identity] = identity.startTimeMicroseconds >= lastTick
                    ? .ok(counters, source: "nettop", at: at)
                    : .unavailable(reason: "this process had traffic before MacMax looked")
                return
            }
            guard counters.bytesIn >= before.bytesIn, counters.bytesOut >= before.bytesOut else {
                result[identity] = .failed(reason: "a traffic counter went backwards")
                return
            }
            result[identity] = .ok(NetworkCounters(bytesIn: counters.bytesIn - before.bytesIn,
                                                   bytesOut: counters.bytesOut - before.bytesOut), source: "nettop", at: at)
        }
    }
}
