import Foundation
import MacMaxCore

// install.sh recognizes a previous MacMax CLI by the literal "macmax-cli:" in this binary; keep it.
func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("macmax-cli: \(message)\n".utf8))
    exit(code)
}

/// `macmax audit [--json] [--ip-check]`: one audit of this Mac; exit 0 ok, 1 warn, 2 crit, 3 unknown.
/// Read-only: it opens the history database for context and never writes to it.
func audit(_ arguments: [String]) async -> Never {
    let known: Set<String> = ["--json", "--ip-check"]
    if arguments.contains(where: { !known.contains($0) }) { fail("unknown option; usage: macmax audit [--json] [--ip-check]") }
    let home = MacMaxHome()
    let databaseURL = home.url.appendingPathComponent("macmax.db")
    // No file is "no history yet"; a file that does not open is a failure the audit must say.
    var database: Database?
    var databaseProblem: String?
    do {
        if try ReportCounter.exists(databaseURL.path) { database = try Database.open(at: databaseURL, mode: .readOnly) }
    } catch { databaseProblem = "the history database could not be opened" }
    let runner = AuditRunner(database: database, databaseProblem: databaseProblem,
                             ipCheckEnabled: arguments.contains("--ip-check"))
    let service = AuditService(database: nil, collect: { previous in await runner.collect(previous: previous) })
    let result = await service.runNow(.onDemand)
    if arguments.contains("--json") {
        do { FileHandle.standardOutput.write(try AuditEnvelope.encode(result.report, generatedAt: Date(timeIntervalSince1970: TimeInterval(result.report.timestamp)), snapshot: result.snapshot) + Data("\n".utf8)) }
        catch { fail("could not encode the audit: \(error.localizedDescription)", code: 70) }
    } else {
        var lines = ["Verdict: \(result.report.verdict.rawValue)"]
        lines += result.report.findings.map { "[\($0.severity.rawValue)] \($0.title)" }
        lines += result.report.unknowns.map { "[unknown] \($0.title): \($0.reason)" }
        print(lines.joined(separator: "\n"))
    }
    exit(AuditExit.code(for: result.report.verdict))
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "audit": await audit(Array(arguments.dropFirst()))
default: fail("usage: macmax audit [--json] [--ip-check]")
}
