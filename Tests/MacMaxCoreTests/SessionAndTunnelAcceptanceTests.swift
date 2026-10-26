import Foundation
import Testing
@testable import MacMaxCore

@Suite("SessionAndTunnelAcceptance")
struct SessionAndTunnelAcceptanceTests {
    @Test("tunnel status reads the direct IPv4 interface")
    func tailscaleTunnelInterface() {
        let status = """
        Connected
        Extended Status <dictionary> {
          IPv4 : <dictionary> {
            Addresses : <array> {
              0 : 192.0.2.44
            }
            InterfaceName : utun9
          }
        }
        """

        #expect(SCUtilNCStatusParser.tunnelInterface(status) == "utun9")
    }

    @Test("tunnel status ignores excluded route physical interfaces")
    func outlineTunnelInterface() {
        let status = """
        Connected
        Extended Status <dictionary> {
          IPv4 : <dictionary> {
            ExcludedRoutes : <array> {
              0 : <dictionary> {
                Address : 198.51.100.0
                InterfaceName : en0
              }
              1 : <dictionary> {
                Address : 203.0.113.0
                InterfaceName : en0
              }
            }
            InterfaceName : utun7
          }
        }
        """

        #expect(SCUtilNCStatusParser.tunnelInterface(status) == "utun7")
    }

    @Test("tunnel status returns nil without a direct interface")
    func missingTunnelInterface() {
        let status = """
        Connected
        Extended Status <dictionary> {
          IPv4 : <dictionary> {
            Addresses : <array> {
              0 : 192.0.2.45
            }
          }
        }
        """

        #expect(SCUtilNCStatusParser.tunnelInterface(status) == nil)
    }

    @Test("disconnected status never reports a tunnel interface")
    func disconnectedTunnelInterface() {
        let status = """
        Disconnected
        Extended Status <dictionary> {
          IPv4 : <dictionary> {
            InterfaceName : utun6
          }
        }
        """

        #expect(SCUtilNCStatusParser.tunnelInterface(status) == nil)
    }

    @Test("network connection parser preserves service IDs without inventing tunnels")
    func serviceIdentifiers() throws {
        let status = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      11111111-2222-3333-4444-555555555555 VPN (com.example.northwind) "Northwind VPN" [VPN:com.example.northwind]
          (Disconnected)   AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE VPN (com.example.contoso) "Contoso Lab" [VPN:com.example.contoso]

        """

        let services = try #require(SCUtilNCParser.parse(status).value)
        #expect(services.map(\.name) == ["Northwind VPN", "Contoso Lab"])
        #expect(services.map(\.bundleID) == ["com.example.northwind", "com.example.contoso"])
        #expect(services.map(\.state) == [.connected, .disconnected])
        #expect(services.map(\.label) == ["Northwind VPN", "Contoso Lab"])
        #expect(services.map(\.serviceID) == ["11111111-2222-3333-4444-555555555555", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"])
        #expect(services.allSatisfy { $0.tunnel == nil })
    }

    @Test("Claude Code sessions use folder names and preserve IDs")
    func sessionFolderNames() throws {
        let groups: [Int32: AppKey] = [
            101: AppKey(id: "claude-code:101", name: "Claude Code"),
            102: AppKey(id: "claude-code:102", name: "Claude Code"),
            103: AppKey(id: "claude-code:103", name: "Claude Code"),
            104: AppKey(id: "claude-code:104", name: "Claude Code"),
            105: AppKey(id: "claude-code:105", name: "Claude Code"),
            201: AppKey(id: "/Applications/Northwind.app", name: "Northwind")
        ]
        let folders: [Int32: String] = [
            101: "/Users/example/Projects/Orchid",
            102: "/Volumes/Work/Orchid",
            103: "/Users/example/Projects/Juniper",
            104: NSHomeDirectory()
        ]

        let named = AppGrouping.nameSessions(groups, folders: folders)

        #expect(named[101]?.name == "Claude Code - Orchid (pid 101)")
        #expect(named[102]?.name == "Claude Code - Orchid (pid 102)")
        #expect(named[103]?.name == "Claude Code - Juniper")
        #expect(named[104]?.name == "Claude Code - ~")
        #expect(named[105]?.name == "Claude Code")
        #expect(named[201] == groups[201])
        #expect(Set(named.keys) == Set(groups.keys))
        for pid in groups.keys {
            let original = try #require(groups[pid])
            #expect(try #require(named[pid]).id == original.id)
        }
    }
}
