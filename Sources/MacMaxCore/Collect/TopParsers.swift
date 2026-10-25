import Foundation

/// One process row of `top -stats pid,command,mem,cmprs,cpu`.
public struct TopProcessRow: Sendable, Equatable {
    public let pid: Int32
    public let command: String
    public let memoryBytes: UInt64?
    public let compressedBytes: UInt64?
    public let cpuPercent: Double?

    public init(pid: Int32, command: String, memoryBytes: UInt64?, compressedBytes: UInt64?, cpuPercent: Double?) {
        self.pid = pid
        self.command = command
        self.memoryBytes = memoryBytes
        self.compressedBytes = compressedBytes
        self.cpuPercent = cpuPercent
    }
}

public enum TopParser {
    /// The rows of the LAST sample block of `top -l N -stats pid,command,mem,cmprs,cpu`: the first block's CPU
    /// is the average since boot, the last one is live. A row keeps its pid when the pid parses; a field that
    /// does not parse is nil, never zero.
    public static func parse(_ text: String, at: Date) -> Reading<[TopProcessRow]> {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else {
            return .failed(reason: "top output has no PID header")
        }
        let rows = lines[(header + 1)...].compactMap(row)
        return .ok(rows, source: "top -l 2", at: at)
    }

    private static func row(_ line: Substring) -> TopProcessRow? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first, let pid = Int32(first) else { return nil }
        guard tokens.count >= 5 else {
            return TopProcessRow(pid: pid, command: tokens.dropFirst().joined(separator: " "),
                                 memoryBytes: nil, compressedBytes: nil, cpuPercent: nil)
        }
        let tail = tokens.suffix(3)
        let command = tokens[1 ..< tokens.count - 3].joined(separator: " ")
        return TopProcessRow(pid: pid, command: command, memoryBytes: size(tail[tail.startIndex]),
                             compressedBytes: size(tail[tail.startIndex + 1]),
                             cpuPercent: Double(tail[tail.startIndex + 2]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }

    /// "12M+", "1536K", "816B" as bytes; the trailing sign says the value moved since the last sample.
    private static func size(_ token: Substring) -> UInt64? {
        let bare = token.last == "+" || token.last == "-" ? token.dropLast() : token
        guard let unit = bare.last, let scale: Double = ["B": 1, "K": 1024, "M": 1_048_576, "G": 1_073_741_824,
                                                         "T": 1_099_511_627_776][unit],
              let number = Double(bare.dropLast()), number >= 0, number.isFinite else { return nil }
        let value = (number * scale).rounded()
        return value < Double(UInt64.max) ? UInt64(value) : UInt64.max
    }
}
