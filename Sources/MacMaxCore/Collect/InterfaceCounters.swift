import Darwin
import Foundation

/// Cumulative 64-bit bytes per network interface.
public enum InterfaceCounters {
    /// From the routing socket's interface list: `getifaddrs` counters are 32-bit and wrap within minutes
    /// on a fast link.
    public static func read(at: Date = .now) -> Reading<[String: NetworkCounters]> {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return .failed(reason: "sysctl NET_RT_IFLIST2 did not answer")
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else {
            return .failed(reason: "sysctl NET_RT_IFLIST2 did not answer")
        }
        var result: [String: NetworkCounters] = [:]
        var offset = 0
        // Every routing message starts with msglen (u16), version (u8), type (u8); address messages are
        // shorter than if_msghdr, so only these four bytes are common to all of them.
        while offset + 4 <= size {
            let length = buffer.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
            guard length >= 4, offset + length <= size else { return .failed(reason: "the interface list is cut off") }
            let type = buffer[offset + 3]
            if type == UInt8(RTM_IFINFO2) {
                guard length >= MemoryLayout<if_msghdr2>.size else { return .failed(reason: "an interface message is too short") }
                let message = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(UInt32(message.ifm_index), &name) != nil else {
                    return .failed(reason: "an interface vanished while its name was read")
                }
                // Loopback is traffic between apps on this Mac, not the network's load.
                let interfaceName = String(nulTerminated: name)
                if interfaceName != "lo0" {
                    result[interfaceName] = NetworkCounters(bytesIn: message.ifm_data.ifi_ibytes,
                                                            bytesOut: message.ifm_data.ifi_obytes)
                }
            }
            offset += length
        }
        guard offset == size else { return .failed(reason: "the interface list is cut off") }
        return result.isEmpty ? .failed(reason: "the interface list was empty") : .ok(result, source: "sysctl NET_RT_IFLIST2", at: at)
    }

    /// Bytes per second per interface between two readings of the same monotonic clock. An interface
    /// whose counter went backwards, or that appeared or vanished, is left out of the result; a clock
    /// that did not advance fails the whole reading.
    public static func rates(from previous: [String: NetworkCounters], previousUptimeNanoseconds: UInt64,
                             to current: [String: NetworkCounters], currentUptimeNanoseconds: UInt64,
                             at: Date = .now) -> Reading<[InterfaceRate]> {
        guard currentUptimeNanoseconds > previousUptimeNanoseconds else {
            return .failed(reason: "the clock did not advance between interface readings")
        }
        let seconds = Double(currentUptimeNanoseconds - previousUptimeNanoseconds) / 1_000_000_000
        let rates = current.compactMap { name, now -> InterfaceRate? in
            guard let before = previous[name], now.bytesIn >= before.bytesIn, now.bytesOut >= before.bytesOut else { return nil }
            return InterfaceRate(name: name, bytesInPerSecond: Double(now.bytesIn - before.bytesIn) / seconds,
                                 bytesOutPerSecond: Double(now.bytesOut - before.bytesOut) / seconds)
        }
        return .ok(rates, source: "sysctl NET_RT_IFLIST2", at: at)
    }
}
