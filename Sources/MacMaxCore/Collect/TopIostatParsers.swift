import Foundation

/// The header of `top -l 2 -n 0`. The first sample's CPU line averages the time since boot, so the
/// parser reads the last header block, which covers the interval.
public struct TopHeader: Sendable, Equatable {
    public let processes: Int
    public let load: LoadAverages
    public let cpuUserPercent, cpuSystemPercent, cpuIdlePercent: Double
    public let physicalUsedBytes, wiredBytes, compressorBytes, unusedBytes: UInt64
    public let swapins, swapouts: UInt64
}

public enum TopHeaderParser {
    public static func parse(_ text: String, at: Date = .now) -> Reading<TopHeader> {
        let lines: [Substring]
        switch ParserSupport.lines(text, tool: "top") {
        case let .success(parsed): lines = parsed
        case let .failure(failure): return .failed(reason: failure.reason)
        }
        // Two blocks are required: the first is the average since boot, so one alone is a run cut short.
        let starts = lines.indices.filter { lines[$0].hasPrefix("Processes:") }
        guard starts.count >= 2, let start = starts.last else {
            return .failed(reason: "top output has no second Processes block")
        }
        let block = lines[start...]
        func line(_ prefix: String) -> Substring? { block.first { $0.hasPrefix(prefix) } }

        guard let processes = line("Processes:")?.firstMatch(of: /Processes:\s+(\d+) total/).flatMap({ Int($0.1) }),
              let load = line("Load Avg:")?.firstMatch(of: /Load Avg:\s+([\d.]+),\s+([\d.]+),\s+([\d.]+)/),
              let one = Double(load.1), let five = Double(load.2), let fifteen = Double(load.3),
              let cpu = line("CPU usage:")?.firstMatch(of: /CPU usage:\s+([\d.]+)% user,\s+([\d.]+)% sys,\s+([\d.]+)% idle/),
              let user = Double(cpu.1), let system = Double(cpu.2), let idle = Double(cpu.3),
              let memory = line("PhysMem:")?.firstMatch(
                  of: /PhysMem:\s+(\S+) used \((\S+) wired, (\S+) compressor\),\s+(\S+) unused\./),
              let used = ParserSupport.bytes(memory.1), let wired = ParserSupport.bytes(memory.2),
              let compressor = ParserSupport.bytes(memory.3), let unused = ParserSupport.bytes(memory.4),
              let vm = line("VM:")?.firstMatch(of: /(\d+)\(\d+\) swapins,\s+(\d+)\(\d+\) swapouts/),
              let swapins = UInt64(vm.1), let swapouts = UInt64(vm.2)
        else { return .failed(reason: "top header is cut off or not understood") }
        guard [user, system, idle].allSatisfy({ (0 ... 100).contains($0) }), abs(user + system + idle - 100) <= 1 else {
            return .failed(reason: "top CPU shares do not add up to 100")
        }
        return .ok(TopHeader(processes: processes, load: LoadAverages(one: one, five: five, fifteen: fifteen),
                             cpuUserPercent: user, cpuSystemPercent: system, cpuIdlePercent: idle,
                             physicalUsedBytes: used, wiredBytes: wired, compressorBytes: compressor,
                             unusedBytes: unused, swapins: swapins, swapouts: swapouts),
                   source: "top -l 2", at: at)
    }
}

/// One device's last row of `iostat -d -c 2 -w 1` (the second row is the interval; the first is
/// the average since boot and is ignored).
public struct DiskIOSample: Sendable, Equatable {
    public let device: String
    public let kilobytesPerTransfer: Double
    public let transfersPerSecond: Double
    public let megabytesPerSecond: Double
}

public enum IostatParser {
    public static func parse(_ text: String, at: Date = .now) -> Reading<[DiskIOSample]> {
        let lines: [Substring]
        switch ParserSupport.lines(text, tool: "iostat") {
        case let .success(parsed): lines = parsed
        case let .failure(failure): return .failed(reason: failure.reason)
        }
        // Two data rows: the first is the average since boot, so one row alone is a run cut short.
        guard lines.count >= 4 else { return .failed(reason: "iostat has no interval data row") }
        let devices = lines[0].split(whereSeparator: \.isWhitespace).map(String.init)
        let columns = lines[1].split(whereSeparator: \.isWhitespace)
        guard !devices.isEmpty, columns.count == devices.count * 3,
              columns.enumerated().allSatisfy({ $0.element == ["KB/t", "tps", "MB/s"][$0.offset % 3] })
        else { return .failed(reason: "iostat header is cut off or not understood") }
        let values = lines[lines.count - 1].split(whereSeparator: \.isWhitespace).map { Double($0) }
        guard values.count == columns.count, values.allSatisfy({ $0.map { $0 >= 0 && $0.isFinite } ?? false }) else {
            return .failed(reason: "iostat data row is cut off or not numeric")
        }
        let samples = devices.enumerated().map { index, device in
            DiskIOSample(device: device, kilobytesPerTransfer: values[index * 3] ?? 0,
                         transfersPerSecond: values[index * 3 + 1] ?? 0, megabytesPerSecond: values[index * 3 + 2] ?? 0)
        }
        return .ok(samples, source: "iostat", at: at)
    }
}

public enum Rate {
    /// Units per second between two samples of a cumulative counter. A counter that went
    /// backwards (reset, wrap) or a clock that did not advance is `failed` for that interval,
    /// never a negative or infinite rate.
    public static func perSecond(from previous: CounterSample, to current: CounterSample,
                                 source: String, at: Date = .now) -> Reading<Double> {
        guard current.uptimeNanoseconds > previous.uptimeNanoseconds else {
            return .failed(reason: "\(source): the clock did not advance between samples")
        }
        guard current.value >= previous.value else {
            return .failed(reason: "\(source): the counter went backwards")
        }
        let seconds = Double(current.uptimeNanoseconds - previous.uptimeNanoseconds) / 1_000_000_000
        return .ok(Double(current.value - previous.value) / seconds, source: source, at: at)
    }
}
