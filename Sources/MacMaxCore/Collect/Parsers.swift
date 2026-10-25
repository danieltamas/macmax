import Foundation

/// Pure text parsers for the command-line fallbacks and the fixtures. A line that is missing,
/// truncated or not a number gives `failed`, never a zero (LESSONS.md section 9, classes 1 and 12).
/// Every tool prints a trailing newline, so text that does not end in one was cut off.
enum ParserSupport {
    static func lines(_ text: String, tool: String) -> Result<[Substring], ParseFailure> {
        guard text.hasSuffix("\n") else { return .failure(ParseFailure("\(tool) output is empty or cut off")) }
        return .success(text.split(separator: "\n", omittingEmptySubsequences: true))
    }

    /// "61G", "90M", "1.5G", "512K", "100B" as bytes; nil for anything else.
    static func bytes(_ token: Substring) -> UInt64? {
        guard let unit = token.last, let scale: Double = ["B": 1, "K": 1024, "M": 1_048_576, "G": 1_073_741_824,
                                                          "T": 1_099_511_627_776][unit],
              let number = Double(token.dropLast()), number >= 0, number.isFinite else { return nil }
        let value = (number * scale).rounded()
        return value < Double(UInt64.max) ? UInt64(value) : nil
    }
}

struct ParseFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// `vm_stat`, one snapshot, in pages.
public struct VMStat: Sendable, Equatable {
    public let pageSize: Int
    public let free, active, inactive, speculative, wired, purgeable: UInt64
    public let fileBacked, anonymous: UInt64
    public let compressorStored, compressorOccupied: UInt64
    public let pageins, pageouts, swapins, swapouts: UInt64
}

public enum VMStatParser {
    private static let required = [
        "Pages free", "Pages active", "Pages inactive", "Pages speculative", "Pages wired down", "Pages purgeable",
        "File-backed pages", "Anonymous pages", "Pages stored in compressor", "Pages occupied by compressor",
        "Pageins", "Pageouts", "Swapins", "Swapouts",
    ]

    public static func parse(_ text: String, at: Date = .now) -> Reading<VMStat> {
        let lines: [Substring]
        switch ParserSupport.lines(text, tool: "vm_stat") {
        case let .success(parsed): lines = parsed
        case let .failure(failure): return .failed(reason: failure.reason)
        }
        guard let header = lines.first, header.hasPrefix("Mach Virtual Memory Statistics:"),
              let size = header.firstMatch(of: /page size of (\d+) bytes/).flatMap({ Int($0.1) }), size > 0
        else { return .failed(reason: "vm_stat has no page size header") }

        var values: [String: UInt64] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.lastIndex(of: ":") else { return .failed(reason: "vm_stat line without a value") }
            let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard raw.hasSuffix("."), let value = UInt64(raw.dropLast()) else {
                return .failed(reason: "vm_stat value for \(key) is not a number")
            }
            values[key] = value
        }
        if let missing = required.first(where: { values[$0] == nil }) {
            return .failed(reason: "vm_stat has no \(missing) line")
        }
        func page(_ key: String) -> UInt64 { values[key] ?? 0 }
        return .ok(VMStat(pageSize: size, free: page("Pages free"), active: page("Pages active"),
                          inactive: page("Pages inactive"), speculative: page("Pages speculative"),
                          wired: page("Pages wired down"), purgeable: page("Pages purgeable"),
                          fileBacked: page("File-backed pages"), anonymous: page("Anonymous pages"),
                          compressorStored: page("Pages stored in compressor"),
                          compressorOccupied: page("Pages occupied by compressor"),
                          pageins: page("Pageins"), pageouts: page("Pageouts"), swapins: page("Swapins"),
                          swapouts: page("Swapouts")), source: "vm_stat", at: at)
    }
}

/// `sysctl vm.swapusage`.
public enum SwapUsageParser {
    public static func parse(_ text: String, at: Date = .now) -> Reading<SwapUsage> {
        guard case let .success(lines) = ParserSupport.lines(text, tool: "vm.swapusage"), lines.count == 1,
              let match = lines[0].wholeMatch(of: /vm\.swapusage: total = (\d+(?:\.\d+)?)M\s+used = (\d+(?:\.\d+)?)M\s+free = (\d+(?:\.\d+)?)M(\s+\(encrypted\))?\s*/),
              let total = ParserSupport.bytes(Substring(match.1 + "M")),
              let used = ParserSupport.bytes(Substring(match.2 + "M")),
              let free = ParserSupport.bytes(Substring(match.3 + "M"))
        else { return .failed(reason: "vm.swapusage output is cut off or not understood") }
        guard used <= total, free <= total, used + free <= total + 1_048_576 else { return .failed(reason: "vm.swapusage totals contradict each other") }
        return .ok(SwapUsage(totalBytes: total, usedBytes: used, freeBytes: free, encrypted: match.4 != nil),
                   source: "sysctl vm.swapusage", at: at)
    }
}

/// `pmset -g therm`. Only a throttled Mac prints `CPU_Speed_Limit`; three "No ... has been
/// recorded" notes mean nothing limits the CPU. Anything else says nothing we can rely on.
public enum PMSetThermParser {
    private static let nominalNotes = [
        "Note: No thermal warning level has been recorded",
        "Note: No performance warning level has been recorded",
        "Note: No CPU power status has been recorded",
    ]

    public static func parse(_ text: String, at: Date = .now) -> Reading<ThermalStatus> {
        let lines: [Substring]
        switch ParserSupport.lines(text, tool: "pmset -g therm") {
        case let .success(parsed): lines = parsed
        case let .failure(failure): return .failed(reason: failure.reason)
        }
        var limit: Int?
        for line in lines where line.contains("CPU_Speed_Limit") {
            guard let equals = line.lastIndex(of: "="),
                  let value = Int(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)),
                  (0 ... 100).contains(value) else { return .failed(reason: "pmset CPU_Speed_Limit is not a percentage") }
            limit = value
        }
        if let limit {
            return .ok(ThermalStatus(state: state(forSpeedLimit: limit), cpuSpeedLimitPercent: limit),
                       source: "pmset -g therm", at: at)
        }
        let trimmed = Set(lines.map { $0.trimmingCharacters(in: .whitespaces) })
        guard nominalNotes.allSatisfy(trimmed.contains) else {
            return .failed(reason: "pmset -g therm output is cut off or not understood")
        }
        return .ok(ThermalStatus(state: .nominal, cpuSpeedLimitPercent: 100), source: "pmset -g therm", at: at)
    }

    static func state(forSpeedLimit limit: Int) -> ThermalState {
        switch limit {
        case 100...: .nominal
        case 75...: .fair
        case 50...: .serious
        default: .critical
        }
    }
}
