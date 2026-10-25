import Foundation
import Testing
@testable import MacMaxCore

private func isFailed<Value>(_ reading: Reading<Value>) -> Bool {
    if case .failed = reading { return true }
    return false
}

private func unavailableWithReason<Value>(_ reading: Reading<Value>) -> Bool {
    if case let .unavailable(reason) = reading { return !reason.isEmpty }
    return false
}

@Suite("NetworkTrafficAcceptance")
struct NetworkTrafficAcceptanceTests {
    @Test("nettop parser accepts exact rows and keeps their order")
    func parserAcceptsRows() throws {
        let fixture = """
        ,bytes_in,bytes_out,
        launchd.1,0,0,
        Example Helper.4242,1500,2500,
        Example App 2.1.4 Helper.4343,10,20,
        Exampl.4444,7,9,

        """

        let snapshot = try #require(NettopParser.parse(fixture).value)
        #expect(snapshot.rows == [
            NettopRow(pid: 1, bytesIn: 0, bytesOut: 0),
            NettopRow(pid: 4242, bytesIn: 1_500, bytesOut: 2_500),
            NettopRow(pid: 4343, bytesIn: 10, bytesOut: 20),
            NettopRow(pid: 4444, bytesIn: 7, bytesOut: 9)
        ])
        #expect(snapshot.skippedRows == 0)
    }

    @Test("bad nettop rows are skipped and counted without becoming zero traffic")
    func parserSkipsBadRows() throws {
        let fixture = """
        ,bytes_in,bytes_out,
        good.102,11,12,
        bad.100,5,
        bad.101,abc,5,
        nopid,5,6,
        negative.103,-1,6,
        empty.104,,6,
        overflow.105,18446744073709551616,6,

        good.106,13,14,

        """

        let snapshot = try #require(NettopParser.parse(fixture).value)
        #expect(snapshot.rows == [
            NettopRow(pid: 102, bytesIn: 11, bytesOut: 12),
            NettopRow(pid: 106, bytesIn: 13, bytesOut: 14)
        ])
        #expect(snapshot.skippedRows == 6)
    }

    @Test("nettop parser accepts UInt64 maximum and a quiet snapshot")
    func parserBoundaries() throws {
        let maximum = ",bytes_in,bytes_out,\nnode.100,18446744073709551615,18446744073709551615,\n"
        let snapshot = try #require(NettopParser.parse(maximum).value)
        #expect(snapshot.rows == [NettopRow(pid: 100, bytesIn: .max, bytesOut: .max)])
        #expect(snapshot.skippedRows == 0)

        let quiet = try #require(NettopParser.parse(",bytes_in,bytes_out,\n").value)
        #expect(quiet.rows.isEmpty)
        #expect(quiet.skippedRows == 0)
    }

    @Test("nettop parser fails closed on missing, wrong, or truncated framing")
    func parserRejectsInvalidDocuments() {
        let invalid = [
            "",
            " \t\n",
            "node.100,1,2,\n",
            ",bytes_out,bytes_in,\nnode.100,1,2,\n",
            ",bytes_in,bytes_out,",
            ",bytes_in,bytes_out,\nnode",
            ",bytes_in,bytes_out,\nnode.100,",
            ",bytes_in,bytes_out,\nnode.100,1,2,"
        ]
        for text in invalid {
            #expect(isFailed(NettopParser.parse(text)), "Expected failed framing for \(String(reflecting: text))")
        }
    }

    @Test("connections parser reads IPv4 established and listening sockets")
    func connectionsIPv4() throws {
        let fixture = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        10:00:00.000001,Example.4242,,,2269,36598,0,0,241,,,,,,,,,,,,
        10:00:00.000002,tcp4 192.0.2.10:51573<->198.51.100.7:443,en0,Established,2269,36598,0,0,241,47.00 ms,131072,31692,BE,-,cubic,-,-,-,-,so,
        10:00:00.000003,tcp4 127.0.0.1:54325<->*:*,lo0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        """ + "\n"

        let connections = try #require(NettopConnectionsParser.parse(fixture).value)
        #expect(connections == [
            NetworkConnection(transport: "tcp4", localAddress: "192.0.2.10", localPort: 51_573,
                              remoteAddress: "198.51.100.7", remotePort: 443,
                              interface: "en0", state: "Established"),
            NetworkConnection(transport: "tcp4", localAddress: "127.0.0.1", localPort: 54_325,
                              remoteAddress: nil, remotePort: nil,
                              interface: "lo0", state: "Listen")
        ])
    }

    @Test("connections parser uses the last dot for IPv6 ports and skips malformed rows")
    func connectionsIPv6AndMalformedRows() throws {
        let fixture = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        10:00:00.000001,Example.4242,,,0,0,0,0,0,,,,,,,,,,,,
        10:00:00.000002,tcp6 2001:db8::1.51574<->2001:db8::2.443,en0,Established,,,,,,,,,,,,,,,,
        10:00:00.000003,not a connection,en0,Established,,,,,,,,,,,,,,,,
        """ + "\n"

        let connections = try #require(NettopConnectionsParser.parse(fixture).value)
        #expect(connections == [
            NetworkConnection(transport: "tcp6", localAddress: "2001:db8::1", localPort: 51_574,
                              remoteAddress: "2001:db8::2", remotePort: 443,
                              interface: "en0", state: "Established")
        ])
    }

    @Test("connections parser enforces header and complete trailing newline")
    func connectionsFraming() throws {
        let header = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,"
        #expect(try #require(NettopConnectionsParser.parse(header + "\n").value).isEmpty)
        for text in ["", " \t\n", "bad,header,\n", header, header + "\n10:00:00"] {
            #expect(isFailed(NettopConnectionsParser.parse(text)))
        }
    }

    @Test("delta tracker differentiates first, increased, and equal readings")
    func deltaBasics() throws {
        let first = ProcessIdentity(pid: 100, startTimeMicroseconds: 100)
        let equal = ProcessIdentity(pid: 101, startTimeMicroseconds: 100)
        var tracker = NetworkDeltaTracker()

        let initial = tracker.update([
            first: NetworkCounters(bytesIn: 1_000, bytesOut: 500),
            equal: NetworkCounters(bytesIn: 20, bytesOut: 30)
        ], tickMicroseconds: 1_000)
        #expect(unavailableWithReason(try #require(initial[first])))
        #expect(unavailableWithReason(try #require(initial[equal])))

        let second = tracker.update([
            first: NetworkCounters(bytesIn: 1_300, bytesOut: 900),
            equal: NetworkCounters(bytesIn: 20, bytesOut: 30)
        ], tickMicroseconds: 2_000)
        #expect(try #require(second[first]?.value) == NetworkCounters(bytesIn: 300, bytesOut: 400))
        #expect(try #require(second[equal]?.value) == NetworkCounters(bytesIn: 0, bytesOut: 0))
    }

    @Test("a backwards counter fails only its identity and maximum values do not trap")
    func deltaFailuresAndMaximum() throws {
        let down = ProcessIdentity(pid: 100, startTimeMicroseconds: 100)
        let sound = ProcessIdentity(pid: 101, startTimeMicroseconds: 100)
        var tracker = NetworkDeltaTracker()
        _ = tracker.update([
            down: NetworkCounters(bytesIn: 10, bytesOut: 20),
            sound: NetworkCounters(bytesIn: UInt64.max - 1, bytesOut: UInt64.max - 2)
        ], tickMicroseconds: 1_000)

        let result = tracker.update([
            down: NetworkCounters(bytesIn: 9, bytesOut: 21),
            sound: NetworkCounters(bytesIn: .max, bytesOut: .max)
        ], tickMicroseconds: 2_000)
        #expect(isFailed(try #require(result[down])))
        #expect(try #require(result[sound]?.value) == NetworkCounters(bytesIn: 1, bytesOut: 2))
    }

    @Test("restarts and newly observed processes use start time relative to the previous tick")
    func deltaNewIdentities() throws {
        let old = ProcessIdentity(pid: 100, startTimeMicroseconds: 100)
        let restarted = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000)
        let startedAtTick = ProcessIdentity(pid: 101, startTimeMicroseconds: 1_000)
        let alreadyRunning = ProcessIdentity(pid: 102, startTimeMicroseconds: 999)
        var tracker = NetworkDeltaTracker()
        _ = tracker.update([old: NetworkCounters(bytesIn: 900, bytesOut: 800)], tickMicroseconds: 1_000)

        let result = tracker.update([
            restarted: NetworkCounters(bytesIn: 7, bytesOut: 9),
            startedAtTick: NetworkCounters(bytesIn: 11, bytesOut: 12),
            alreadyRunning: NetworkCounters(bytesIn: 13, bytesOut: 14)
        ], tickMicroseconds: 2_000)
        #expect(try #require(result[restarted]?.value) == NetworkCounters(bytesIn: 7, bytesOut: 9))
        #expect(try #require(result[startedAtTick]?.value) == NetworkCounters(bytesIn: 11, bytesOut: 12))
        #expect(unavailableWithReason(try #require(result[alreadyRunning])))
    }

    @Test("an absent identity is forgotten and empty ticks advance time")
    func deltaForgetsAbsentIdentities() throws {
        let identity = ProcessIdentity(pid: 100, startTimeMicroseconds: 100)
        var tracker = NetworkDeltaTracker()
        _ = tracker.update([identity: NetworkCounters(bytesIn: 10, bytesOut: 10)], tickMicroseconds: 1_000)
        #expect(tracker.update([:], tickMicroseconds: 2_000).isEmpty)

        let returned = tracker.update([identity: NetworkCounters(bytesIn: 20, bytesOut: 20)], tickMicroseconds: 3_000)
        #expect(unavailableWithReason(try #require(returned[identity])))

        let newIdentity = ProcessIdentity(pid: 101, startTimeMicroseconds: 3_000)
        let afterEmpty = tracker.update([:], tickMicroseconds: 4_000)
        #expect(afterEmpty.isEmpty)
        let newResult = tracker.update([newIdentity: NetworkCounters(bytesIn: 5, bytesOut: 6)], tickMicroseconds: 5_000)
        #expect(unavailableWithReason(try #require(newResult[newIdentity])))
    }

    @Test("interface rates use the shared intersection and elapsed monotonic time")
    func interfaceRates() throws {
        let rates = try #require(InterfaceCounters.rates(
            from: [
                "en0": NetworkCounters(bytesIn: 1_000, bytesOut: 500),
                "vanished": NetworkCounters(bytesIn: 1, bytesOut: 1),
                "backwards": NetworkCounters(bytesIn: 50, bytesOut: 50)
            ], previousUptimeNanoseconds: 1_000_000_000,
            to: [
                "en0": NetworkCounters(bytesIn: 3_000, bytesOut: 1_500),
                "appeared": NetworkCounters(bytesIn: 1, bytesOut: 1),
                "backwards": NetworkCounters(bytesIn: 49, bytesOut: 51)
            ], currentUptimeNanoseconds: 3_000_000_000
        ).value)
        let en0 = try #require(rates.first { $0.name == "en0" })
        #expect(abs(en0.bytesInPerSecond - 1_000) <= 1e-9)
        #expect(abs(en0.bytesOutPerSecond - 500) <= 1e-9)
        #expect(rates.count == 1)
    }

    @Test("interface rates reject a nonadvancing clock and accept an empty intersection")
    func interfaceRateEdges() throws {
        let counters = ["en0": NetworkCounters(bytesIn: 1, bytesOut: 1)]
        #expect(isFailed(InterfaceCounters.rates(from: counters, previousUptimeNanoseconds: 2,
                                                 to: counters, currentUptimeNanoseconds: 2)))
        #expect(isFailed(InterfaceCounters.rates(from: counters, previousUptimeNanoseconds: 2,
                                                 to: counters, currentUptimeNanoseconds: 1)))
        let empty = try #require(InterfaceCounters.rates(
            from: ["en0": NetworkCounters(bytesIn: 1, bytesOut: 1)], previousUptimeNanoseconds: 1,
            to: ["en1": NetworkCounters(bytesIn: 2, bytesOut: 2)], currentUptimeNanoseconds: 2
        ).value)
        #expect(empty.isEmpty)
    }

    @Test("first collection withholds all deltas without reporting failures")
    func firstCollection() async throws {
        let samples = try #require((await ProcessCollector().collect()).value)
        let snapshot = await NetworkCollector().collect(processes: samples)

        #expect(snapshot.skippedRows >= 0)
        #expect(unavailableWithReason(snapshot.interfaces))
        let processReadings = try #require(snapshot.processes.value)
        #expect(processReadings.values.allSatisfy(unavailableWithReason))
        #expect(!isFailed(snapshot.processes))
        #expect(!isFailed(snapshot.interfaces))

        let interfaces = try #require(InterfaceCounters.read().value)
        #expect(!interfaces.isEmpty)
        #expect(interfaces["lo0"] == nil)
    }
}
