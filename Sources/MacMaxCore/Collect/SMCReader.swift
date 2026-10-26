import Foundation
import IOKit

/// Reads keys from the System Management Controller through its IOKit user client. This needs no root: it is the same
/// read that Activity Monitor-style tools use. The keys are model specific and undocumented, so every failure here is
/// "unknown" and the summary (ThermalSensorSummary) decides what an absent key means.
enum SMCReader {
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    /// Padded to 12 bytes by hand: C pads a nested struct to its alignment, Swift does not, and the kernel reads the C layout.
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0, pad3: UInt8 = 0 }
    private struct Bytes32 {
        var b0: UInt64 = 0, b1: UInt64 = 0, b2: UInt64 = 0, b3: UInt64 = 0
    }
    private struct Call {
        var key: UInt32 = 0
        var version = Version()
        var limit = PowerLimit()
        var info = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var index: UInt32 = 0
        var bytes = Bytes32()
    }

    private static let handleEvent: UInt32 = 2
    private static let readBytes: UInt8 = 5, readKeyInfo: UInt8 = 9, keyAtIndex: UInt8 = 8

    /// Every temperature key and the fan keys, decoded. `unavailable` when this Mac has no SMC service at all, `failed`
    /// when it exists but cannot be read in full: a key list with holes, or a fan or count key that will not decode.
    /// A temperature key or a fan limit that will not read is skipped (many keys are placeholders); the fan count and current speeds are required.
    static func readings(at: Date = .now) -> Reading<[String: Double]> {
        // The offsets the kernel's struct has: a wrong layout would read other bytes, so it is refused, not tried.
        guard MemoryLayout<Call>.size == 80, MemoryLayout<KeyInfo>.size == 12, MemoryLayout<Call>.offset(of: \.key) == 0,
              MemoryLayout<Call>.offset(of: \.version) == 4, MemoryLayout<Call>.offset(of: \.limit) == 12,
              MemoryLayout<Call>.offset(of: \.info) == 28, MemoryLayout<Call>.offset(of: \.result) == 40,
              MemoryLayout<Call>.offset(of: \.status) == 41, MemoryLayout<Call>.offset(of: \.command) == 42,
              MemoryLayout<Call>.offset(of: \.index) == 44, MemoryLayout<Call>.offset(of: \.bytes) == 48 else {
            return .failed(reason: "the sensor interface layout is not the expected one")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return .unavailable(reason: "this Mac has no sensor controller") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return .failed(reason: "the sensor controller could not be opened")
        }
        defer { IOServiceClose(connection) }

        var values: [String: Double] = [:]
        guard let count = value(of: "#KEY", connection), count >= 1, count < 10_000, count == count.rounded() else {
            return .failed(reason: "the sensor key count could not be read")
        }
        for index in 0 ..< UInt32(count) {
            guard let key = key(at: index, connection) else { return .failed(reason: "the sensor key list has a gap") }
            let required = key == "FNum" || (key.count == 4 && key.hasPrefix("F") && key.dropFirst().first?.isNumber == true && key.hasSuffix("Ac"))
            let optional = key.count == 4 && key.hasPrefix("F") && key.dropFirst().first?.isNumber == true && (key.hasSuffix("Mn") || key.hasSuffix("Mx"))
            guard key.hasPrefix("T") || required || optional else { continue }
            if let decoded = value(of: key, connection) { values[key] = decoded } else if required { return .failed(reason: "the fan key \(key) could not be read") }
        }
        return .ok(values, source: "AppleSMC", at: at)
    }

    private static func call(_ input: Call, _ connection: io_connect_t) -> Call? {
        var input = input
        var output = Call()
        var size = MemoryLayout<Call>.size
        let status = IOConnectCallStructMethod(connection, handleEvent, &input, MemoryLayout<Call>.size, &output, &size)
        // A short answer leaves the rest zeroed: it must not read as data.
        return status == KERN_SUCCESS && output.result == 0 && size == MemoryLayout<Call>.size ? output : nil
    }

    private static func key(at index: UInt32, _ connection: io_connect_t) -> String? {
        var input = Call()
        input.command = keyAtIndex
        input.index = index
        return call(input, connection).map { text($0.key) }
    }

    private static func value(of key: String, _ connection: io_connect_t) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        var input = Call()
        input.key = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        input.command = readKeyInfo
        guard let described = call(input, connection), (1 ... 32).contains(described.info.dataSize) else { return nil }
        input.info.dataSize = described.info.dataSize
        input.command = readBytes
        guard let read = call(input, connection) else { return nil }
        let bytes = withUnsafeBytes(of: read.bytes) { Array($0.prefix(Int(described.info.dataSize))) }
        return SMCDecoder.decode(type: text(described.info.dataType), bytes: bytes)
    }

    private static func text(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}
