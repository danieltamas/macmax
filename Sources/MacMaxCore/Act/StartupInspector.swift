import Foundation

/// Everything the detail view of one background item shows. It only reads.
public struct StartupInspection: Sendable, Equatable {
    public let detail: StartupDetail?
    public let pid: Int?
    /// nil when launchctl could not be asked; false only when launchctl answered and the label has no process.
    public let isRunning: Bool?
    /// nil when they could not be read (not running, or lsof failed): "no connections" is a different answer.
    public let connections: [ProcessConnection]?

    public init(detail: StartupDetail?, pid: Int?, isRunning: Bool? = nil, connections: [ProcessConnection]?) {
        self.detail = detail
        self.pid = pid
        self.isRunning = isRunning ?? (pid != nil ? true : nil)
        self.connections = connections
    }
}

public struct StartupInspector: Sendable {
    private let runner = ProcessRunner()

    public init() {}

    public func inspect(_ item: StartupItem) async -> StartupInspection {
        var detail: StartupDetail?
        if let data = StartupScanner.readPlist(at: item.path), case let .ok(parsed, _, _) = StartupDetailParser.parse(data) { detail = parsed }
        // Asked again now: the list the row came from may be minutes old.
        guard let labels = await pids() else { return StartupInspection(detail: detail, pid: nil, connections: nil) }
        guard let pid = labels[item.label] else { return StartupInspection(detail: detail, pid: nil, isRunning: false, connections: nil) }
        let before = await startTime(of: pid)
        // lsof exits 1 with no output when the process has no sockets; an error message makes it a failed read.
        guard before != nil, let sockets = try? await runner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-i"], timeout: .seconds(10)),
              sockets.stderr.isEmpty, sockets.status == 0 || (sockets.status == 1 && sockets.stdout.isEmpty)
        else { return StartupInspection(detail: detail, pid: pid, connections: nil) }
        // A pid can be reused between the commands: the sockets are shown only for the process that was asked about.
        guard await pids()?[item.label] == pid, await startTime(of: pid) == before else { return StartupInspection(detail: detail, pid: pid, connections: nil) }
        return StartupInspection(detail: detail, pid: pid, connections: LsofConnections.parseAll(String(decoding: sockets.stdout, as: UTF8.self)))
    }

    private func pids() async -> [String: Int]? {
        guard let list = try? await runner.run("/bin/launchctl", ["list"], timeout: .seconds(10)), list.status == 0 else { return nil }
        let text = String(decoding: list.stdout, as: UTF8.self)
        // A line that is not `pid, status, label` means the format is not the one this reads: not an answer.
        let rows = text.split(whereSeparator: \.isNewline).dropFirst()
        guard text.hasPrefix("PID"), rows.allSatisfy({ $0.split(separator: "\t", omittingEmptySubsequences: false).count == 3 }) else { return nil }
        return LaunchctlList.pids(text)
    }

    private func startTime(of pid: Int) async -> String? {
        guard let output = try? await runner.run("/bin/ps", ["-o", "lstart=", "-p", String(pid)], timeout: .seconds(5)), output.status == 0 else { return nil }
        let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
