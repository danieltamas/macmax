import Foundation
import Testing
@testable import MacMaxCore

@Suite("Audit parser acceptance")
struct AuditParsersAcceptanceTests {
    @Test("TopParser rejects input without a sample header", arguments: ["", "   \n", "Processes: 1 total\nnoise"])
    func topRequiresHeader(text: String) {
        guard case let .failed(reason) = TopParser.parse(text, at: Date(timeIntervalSince1970: 1)) else {
            Issue.record("input without a PID header must fail")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("TopParser returns only the final block and preserves spaced commands")
    func topLastBlock() {
        let text = """
        Processes: 2 total
        PID COMMAND MEM CMPRS %CPU
        11 First Process 1G 12M+ 9.5
        Load Avg: 1.0

        PID    COMMAND          MEM    CMPRS  %CPU
        0 kernel_task 816B 0B 0.0
        22 Google Chrome Helper 1536K 12M- 12.5
        """
        let result = TopParser.parse(text, at: Date(timeIntervalSince1970: 2))
        guard case let .ok(rows, _, _) = result else {
            Issue.record("valid top blocks must parse")
            return
        }
        #expect(rows == [
            TopProcessRow(pid: 0, command: "kernel_task", memoryBytes: 816, compressedBytes: 0, cpuPercent: 0),
            TopProcessRow(pid: 22, command: "Google Chrome Helper", memoryBytes: 1_572_864,
                          compressedBytes: 12_582_912, cpuPercent: 12.5),
        ])
    }

    @Test("TopParser accepts an empty final block")
    func topEmptyLastBlock() {
        let text = "PID COMMAND MEM CMPRS %CPU\n7 Old 1M 2M 3.0\nPID COMMAND MEM CMPRS %CPU\nCPU usage: 1%"
        guard case let .ok(rows, _, _) = TopParser.parse(text, at: Date()) else {
            Issue.record("a header-only final block is valid")
            return
        }
        #expect(rows.isEmpty)
    }

    @Test("TopParser keeps parsable pids and makes each malformed field nil")
    func topMalformedFields() {
        let text = """
        PID COMMAND MEM CMPRS %CPU
        nope Ignored 1M 2M 3.0
        31 Too Short 1M
        32 Bad Memory nope 2M 3.0
        33 Bad Compressed 1M nope 4.0
        34 Bad CPU 1M 2M nope
        """
        guard case let .ok(rows, _, _) = TopParser.parse(text, at: Date()) else {
            Issue.record("header must produce a reading")
            return
        }
        #expect(rows.map(\.pid) == [31, 32, 33, 34])
        #expect(rows[0].memoryBytes == nil)
        #expect(rows[0].compressedBytes == nil)
        #expect(rows[0].cpuPercent == nil)
        #expect(rows[1].memoryBytes == nil)
        #expect(rows[1].compressedBytes == 2_097_152)
        #expect(rows[2].compressedBytes == nil)
        #expect(rows[3].cpuPercent == nil)
    }

    @Test("TopParser uses binary units and saturates overflow")
    func topUnitsAndOverflow() {
        let text = "PID COMMAND MEM CMPRS %CPU\n1 Example App 1G 17179869184G 0.0"
        guard case let .ok(rows, _, _) = TopParser.parse(text, at: Date()), let row = rows.first else {
            Issue.record("valid unit row must parse")
            return
        }
        #expect(row.memoryBytes == 1_073_741_824)
        #expect(row.compressedBytes == UInt64.max)
    }

    @Test("ReportCounter sums matching recent regular files across directories")
    func reportCounterCountsBoundaries() throws {
        let root = try temporaryAuditDirectory("ReportCounter")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let now = Date(timeIntervalSince1970: 2_000_000)
        try makeAuditFile(first.appendingPathComponent("recent.crash"), modified: now.addingTimeInterval(-6 * 86_400))
        try makeAuditFile(first.appendingPathComponent("boundary.crash"), modified: now.addingTimeInterval(-7 * 86_400))
        try makeAuditFile(second.appendingPathComponent("future.crash"), modified: now.addingTimeInterval(60))
        try makeAuditFile(second.appendingPathComponent("ignored.txt"), modified: now)
        try FileManager.default.createDirectory(at: second.appendingPathComponent("folder.crash"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: second.appendingPathComponent("link.crash"),
                                                   withDestinationURL: first.appendingPathComponent("recent.crash"))
        let missing = root.appendingPathComponent("missing")
        let reading = ReportCounter.count(in: [first, second, missing], matching: { $0.hasSuffix(".crash") },
                                          modifiedWithinDays: 7, now: now, at: now)
        #expect(reading.value == 2)
    }

    @Test("ReportCounter fails closed when an existing directory cannot be read")
    func reportCounterDeniedDirectory() throws {
        let root = try temporaryAuditDirectory("ReportCounterDenied")
        defer { try? FileManager.default.removeItem(at: root) }
        let readable = root.appendingPathComponent("readable", isDirectory: true)
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        try makeAuditFile(readable.appendingPathComponent("one.crash"), modified: Date())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        guard case let .failed(reason) = ReportCounter.count(in: [readable, denied], matching: { _ in true },
                                                             modifiedWithinDays: 7, now: Date()) else {
            Issue.record("an unreadable directory must fail the whole reading")
            return
        }
        #expect(!reason.isEmpty)
    }
}

private func makeAuditFile(_ url: URL, modified: Date) throws {
    try Data("fixture".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}
