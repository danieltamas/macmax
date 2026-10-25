import Foundation

public struct NettopRow: Sendable, Equatable {
    public let pid: Int32
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(pid: Int32, bytesIn: UInt64, bytesOut: UInt64) {
        self.pid = pid
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct NettopSnapshot: Sendable, Equatable {
    public let rows: [NettopRow]
    public let skippedRows: Int

    public init(rows: [NettopRow], skippedRows: Int) {
        self.rows = rows
        self.skippedRows = skippedRows
    }
}

/// `nettop -P -L 1 -x -J bytes_in,bytes_out`: a header, then `name.pid,bytes_in,bytes_out,` per process.
/// The name is not read (it can hold dots and spaces and be truncated); the process collector knows
/// the name by pid. A row that does not parse is skipped and counted, never read as zero traffic.
public enum NettopParser {
    private static let header = ",bytes_in,bytes_out,"

    public static func parse(_ text: String, at: Date = .now) -> Reading<NettopSnapshot> {
        let lines: [Substring]
        switch ParserSupport.lines(text, tool: "nettop") {
        case let .success(parsed): lines = parsed.filter { !$0.allSatisfy(\.isWhitespace) }
        case let .failure(failure): return .failed(reason: failure.reason)
        }
        guard lines.first == Substring(header) else { return .failed(reason: "nettop header is missing or not understood") }
        var rows: [NettopRow] = []
        var skipped = 0
        for line in lines.dropFirst() {
            if let row = row(line) { rows.append(row) } else { skipped += 1 }
        }
        return .ok(NettopSnapshot(rows: rows, skippedRows: skipped), source: "nettop", at: at)
    }

    private static func row(_ line: Substring) -> NettopRow? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[3].isEmpty,
              let dot = fields[0].lastIndex(of: "."),
              let pid = Int32(fields[0][fields[0].index(after: dot)...]), pid > 0,
              let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else { return nil }
        return NettopRow(pid: pid, bytesIn: bytesIn, bytesOut: bytesOut)
    }
}

/// `nettop -m tcp -L 1 -x -n -p <pid>`: the connections of one process. The first row of a block is the
/// process summary (no `<->`); it is not a connection and is not an error.
public enum NettopConnectionsParser {
    public static func parse(_ text: String, at: Date = .now) -> Reading<[NetworkConnection]> {
        let lines: [Substring]
        switch ParserSupport.lines(text, tool: "nettop") {
        case let .success(parsed): lines = parsed.filter { !$0.allSatisfy(\.isWhitespace) }
        case let .failure(failure): return .failed(reason: failure.reason)
        }
        guard let first = lines.first, first.hasPrefix("time,,interface,state,bytes_in,bytes_out,") else {
            return .failed(reason: "nettop connection header is missing or not understood")
        }
        return .ok(lines.dropFirst().compactMap(connection), source: "nettop", at: at)
    }

    private static func connection(_ line: Substring) -> NetworkConnection? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count > 3, fields[1].contains("<->") else { return nil }
        let parts = fields[1].split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let ends = parts[1].components(separatedBy: "<->")
        guard ends.count == 2, let local = endpoint(ends[0]), local.port != nil, let localPort = local.port else { return nil }
        guard let remote = endpoint(ends[1]) else { return nil }
        let isWildcard = remote.address == "*"
        return NetworkConnection(
            transport: String(parts[0]), localAddress: local.address, localPort: localPort,
            remoteAddress: isWildcard ? nil : remote.address, remotePort: isWildcard ? nil : remote.port,
            interface: String(fields[2]), state: String(fields[3]))
    }

    /// `192.0.2.10:443` (IPv4 uses `:`) or `2001:db8::1.443` (IPv6 uses `.`): split at the last separator.
    private static func endpoint(_ text: String) -> (address: String, port: Int?)? {
        guard let split = text.lastIndex(where: { $0 == ":" || $0 == "." }) else { return nil }
        let address = String(text[..<split]), port = String(text[text.index(after: split)...])
        guard !address.isEmpty else { return nil }
        if port == "*" { return (address, nil) }
        guard let number = Int(port), (0 ... 65535).contains(number) else { return nil }
        return (address, number)
    }
}
