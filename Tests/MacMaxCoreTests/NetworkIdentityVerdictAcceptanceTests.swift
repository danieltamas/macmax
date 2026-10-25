import Foundation
import Testing
@testable import MacMaxCore

private enum VerdictReadingFailure: CaseIterable {
    case none, vpnFailed, routeFailed, publicFailed, ispFailed
    case vpnUnavailable, routeUnavailable, publicUnavailable, ispUnavailable
}

private func verdictReading<T: Sendable>(
    _ value: T,
    failed: Bool,
    unavailable: Bool
) -> Reading<T> {
    if failed { return .failed(reason: "synthetic failure") }
    if unavailable { return .unavailable(reason: "synthetic unavailable") }
    return .ok(value, source: "fixture", at: Date(timeIntervalSince1970: 1))
}

private func expectedVerdict(
    enabled: Bool,
    connected: Bool,
    tunnel: Bool,
    equalIPs: Bool,
    failure: VerdictReadingFailure
) -> LeakVerdict {
    if !enabled { return .off }
    if failure != .none { return .unknown }
    if !connected && !tunnel { return .noVPN }
    if equalIPs { return .leak }
    return tunnel ? .tunnelOK : .splitTunnel
}

@Suite("NetworkIdentityVerdictAcceptance")
struct NetworkIdentityVerdictAcceptanceTests {
    @Test("verdict exhaustively follows the first-match table")
    func exhaustiveVerdictTable() {
        for enabled in [false, true] {
            for connected in [false, true] {
                for tunnel in [false, true] {
                    for equalIPs in [false, true] {
                        for failure in VerdictReadingFailure.allCases {
                            let services = connected
                                ? [VPNService(name: "Example VPN", bundleID: "com.example.vpn",
                                              state: .connected, label: "Example VPN")]
                                : [VPNService(name: "Example VPN", bundleID: "com.example.vpn",
                                              state: .disconnected, label: "Example VPN")]
                            let publicAddress = "198.51.100.7"
                            let ispAddress = equalIPs ? publicAddress : "203.0.113.9"
                            let actual = LeakVerdictEngine.verdict(
                                checkEnabled: enabled,
                                vpnServices: verdictReading(
                                    services,
                                    failed: failure == .vpnFailed,
                                    unavailable: failure == .vpnUnavailable
                                ),
                                route: verdictReading(
                                    DefaultRoute(interface: tunnel ? "utun7" : "en0", isTunnel: tunnel),
                                    failed: failure == .routeFailed,
                                    unavailable: failure == .routeUnavailable
                                ),
                                publicIP: verdictReading(
                                    PublicIP(address: publicAddress, country: "RO"),
                                    failed: failure == .publicFailed,
                                    unavailable: failure == .publicUnavailable
                                ),
                                ispIP: verdictReading(
                                    PublicIP(address: ispAddress, country: "DE"),
                                    failed: failure == .ispFailed,
                                    unavailable: failure == .ispUnavailable
                                )
                            )
                            let expected = expectedVerdict(
                                enabled: enabled, connected: connected, tunnel: tunnel,
                                equalIPs: equalIPs, failure: failure
                            )
                            #expect(actual == expected, "enabled=\(enabled), connected=\(connected), tunnel=\(tunnel), equal=\(equalIPs), failure=\(failure)")
                        }
                    }
                }
            }
        }
    }

    @Test("only connected services count as VPN use")
    func transitionalStatesAreNotInUse() {
        for state in [VPNState.connecting, .disconnected, .disconnecting, .invalid] {
            let services: Reading<[VPNService]> = .ok([
                VPNService(name: "Example VPN", bundleID: "com.example.vpn", state: state,
                           label: "Example VPN")
            ], source: "fixture", at: .now)
            let verdict = LeakVerdictEngine.verdict(
                checkEnabled: true,
                vpnServices: services,
                route: .ok(DefaultRoute(interface: "en0", isTunnel: false), source: "fixture", at: .now),
                publicIP: .ok(PublicIP(address: "198.51.100.7", country: nil), source: "fixture", at: .now),
                ispIP: .ok(PublicIP(address: "198.51.100.7", country: nil), source: "fixture", at: .now)
            )
            #expect(verdict == .noVPN)
        }
    }

    @Test("address comparison ignores country, handles families, and normalizes IPv6 case")
    func addressComparison() {
        let connected: Reading<[VPNService]> = .ok([
            VPNService(name: "Example VPN", bundleID: "com.example.vpn", state: .connected,
                       label: "Example VPN")
        ], source: "fixture", at: .now)
        let route: Reading<DefaultRoute> = .ok(
            DefaultRoute(interface: "utun7", isTunnel: true), source: "fixture", at: .now
        )

        #expect(LeakVerdictEngine.verdict(
            checkEnabled: true, vpnServices: connected, route: route,
            publicIP: .ok(PublicIP(address: "198.51.100.7", country: "RO"), source: "fixture", at: .now),
            ispIP: .ok(PublicIP(address: "198.51.100.7", country: "DE"), source: "fixture", at: .now)
        ) == .leak)
        #expect(LeakVerdictEngine.verdict(
            checkEnabled: true, vpnServices: connected, route: route,
            publicIP: .ok(PublicIP(address: "2001:db8::1", country: nil), source: "fixture", at: .now),
            ispIP: .ok(PublicIP(address: "2001:DB8::1", country: nil), source: "fixture", at: .now)
        ) == .leak)
        #expect(LeakVerdictEngine.verdict(
            checkEnabled: true, vpnServices: connected, route: route,
            publicIP: .ok(PublicIP(address: "2001:db8::1", country: nil), source: "fixture", at: .now),
            ispIP: .ok(PublicIP(address: "198.51.100.1", country: nil), source: "fixture", at: .now)
        ) == .tunnelOK)
    }
}
