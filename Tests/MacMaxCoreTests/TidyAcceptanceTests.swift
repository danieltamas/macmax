import Testing
@testable import MacMaxCore

@Suite("Tidy acceptance")
struct TidyAcceptanceTests {
    @Test("ps rows preserve commands and skip malformed lines")
    func parsesPSOutput() {
        let input = """
              101     1 S /usr/local/bin/supergateway --stdio transport
              202   101 Z+ /opt/tools/finished worker
              303   101 R
            missing fields
              404 nope S /bin/bad-parent
              505   101
            """

        let rows = TidyParser.parse(input)

        #expect(rows == [
            PsRow(pid: 101, parentPid: 1, state: "S", command: "/usr/local/bin/supergateway --stdio transport"),
            PsRow(pid: 202, parentPid: 101, state: "Z+", command: "/opt/tools/finished worker"),
            PsRow(pid: 303, parentPid: 101, state: "R", command: ""),
        ])
        #expect(rows.map(\.name) == ["supergateway", "finished", ""])
    }

    @Test("Every documented MCP sidecar marker is recognized")
    func recognizesMCPSidecars() {
        let sidecars = [
            "node supergateway --stdio",
            "node playwright-mcp",
            "node @playwright/mcp",
            "python server-pdf",
            "node context7",
            "node mcp-remote https://example.invalid",
            "python mcp-wrapper",
            "npm exec example-server",
        ]

        for command in sidecars {
            #expect(TidyAnalysis.isMCPSidecar(command), "Expected sidecar marker in: \(command)")
        }
        #expect(!TidyAnalysis.isMCPSidecar("/Applications/Orbit.app/Contents/MacOS/Orbit --foreground"))
    }

    @Test("Only orphaned non-zombie MCP sidecars are stale")
    func findsStaleMCPSidecars() {
        let rows = [
            PsRow(pid: 10, parentPid: 1, state: "S", command: "/usr/bin/session-host"),
            PsRow(pid: 11, parentPid: 10, state: "S", command: "node context7"),
            PsRow(pid: 12, parentPid: 1, state: "S", command: "node mcp-remote"),
            PsRow(pid: 13, parentPid: 999, state: "S", command: "npm exec sidecar"),
            PsRow(pid: 14, parentPid: 999, state: "S", command: "/usr/bin/ordinary-worker"),
            PsRow(pid: 15, parentPid: 1, state: "Z", command: "node supergateway"),
        ]

        #expect(TidyAnalysis.staleMCP(rows).map(\.pid) == [12, 13])
    }

    @Test("Zombie rows and running parents are reported with deterministic ordering")
    func reportsZombiesAndParents() {
        let rows = [
            PsRow(pid: 40, parentPid: 1, state: "S", command: "/opt/tools/parent-forty"),
            PsRow(pid: 20, parentPid: 1, state: "S", command: "/opt/tools/parent-twenty"),
            PsRow(pid: 30, parentPid: 1, state: "S", command: "/opt/tools/parent-thirty"),
            PsRow(pid: 41, parentPid: 40, state: "Z", command: "finished-a"),
            PsRow(pid: 42, parentPid: 40, state: "Z+", command: "finished-b"),
            PsRow(pid: 21, parentPid: 20, state: "Z", command: "finished-c"),
            PsRow(pid: 31, parentPid: 30, state: "Z", command: "finished-d"),
            PsRow(pid: 50, parentPid: 1, state: "Z", command: "launchd-child"),
            PsRow(pid: 51, parentPid: 999, state: "Z", command: "absent-parent-child"),
            PsRow(pid: 52, parentPid: 40, state: "S", command: "running-child"),
        ]

        #expect(TidyAnalysis.zombies(rows).map(\.pid) == [41, 42, 21, 31, 50, 51])
        let parents = TidyAnalysis.zombieParents(rows)
        #expect(parents.map { $0.parent.pid } == [40, 20, 30])
        #expect(parents.map(\.zombies) == [2, 1, 1])
    }
}
