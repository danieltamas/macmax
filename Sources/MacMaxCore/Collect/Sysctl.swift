import Darwin
import Foundation

/// Typed `sysctlbyname` reads. A call that fails or returns a short value is nil, never zero.
enum Sysctl {
    static func int32(_ name: String) -> Int32? { value(name, as: Int32.self) }
    static func uint64(_ name: String) -> UInt64? { value(name, as: UInt64.self) }

    static func value<T>(_ name: String, as type: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.pointee
    }

    /// `hw.memsize` is 64-bit but some counters answer with 32; accept either width.
    static func unsigned(_ name: String) -> UInt64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return int32(name).map { UInt64(UInt32(bitPattern: $0)) }
        case 8: return uint64(name)
        default: return nil
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
