import Darwin
import Foundation
import Testing
@testable import MacMaxCore

private func identityFailed<T>(_ reading: Reading<T>) -> Bool {
    if case .failed = reading { return true }
    return false
}

private func identityUnavailableWithReason<T>(_ reading: Reading<T>) -> Bool {
    if case let .unavailable(reason) = reading { return !reason.isEmpty }
    return false
}

private final class IdentityHTTPServer: @unchecked Sendable {
    enum Behavior { case response(Int, String), neverRespond }
    private let descriptor: Int32
    private let behavior: Behavior
    private let queue = DispatchQueue(label: "ro.danieltamas.macmax.tests.identity-http")
    private let lock = NSLock()
    private var requests = 0
    let port: Int

    init(_ behavior: Behavior) throws {
        self.behavior = behavior
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                         socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: bound.sin_port))
        queue.async { [self] in serve() }
    }

    var requestCount: Int { lock.withLock { requests } }
    var endpoint: String { "http://127.0.0.1:\(port)/" }

    func stop() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func serve() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            lock.withLock { requests += 1 }
            switch behavior {
            case let .response(status, body):
                var request = [UInt8](repeating: 0, count: 2_048)
                _ = recv(client, &request, request.count, 0)
                let reason = status == 200 ? "OK" : "Error"
                let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                response.withCString { pointer in
                    _ = Darwin.send(client, pointer, strlen(pointer), 0)
                }
            case .neverRespond:
                var request = [UInt8](repeating: 0, count: 2_048)
                _ = recv(client, &request, request.count, 0)
                Thread.sleep(forTimeInterval: 6)
            }
            Darwin.close(client)
        }
    }
}

@Suite("NetworkIdentityAcceptance")
struct NetworkIdentityAcceptanceTests {
    @Test("scutil parser reads states, labels, embedded quotes, and input order")
    func scutilServices() throws {
        let fixture = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      00000000-0000-0000-0000-000000000001 VPN (org.outline.macos.client) "Example Server" [VPN:org.outline.macos.client]
          (Disconnected)   00000000-0000-0000-0000-000000000002 VPN (io.tailscale.ipn.macsys) "Example VPN" [VPN:io.tailscale.ipn.macsys]
        * (Connecting)     00000000-0000-0000-0000-000000000003 VPN (com.example.vpn) "Home "Lab" VPN" [VPN:com.example.vpn]

        """
        let services = try #require(SCUtilNCParser.parse(fixture).value)
        #expect(services.map(\.state) == [.connected, .disconnected, .connecting])
        #expect(services.map(\.name) == ["Example Server", "Example VPN", "Home \"Lab\" VPN"])
        #expect(services.map(\.bundleID) == ["org.outline.macos.client", "io.tailscale.ipn.macsys", "com.example.vpn"])
        #expect(services.map(\.label) == ["Outline", "Tailscale", "Home \"Lab\" VPN"])
    }

    @Test("scutil parser accepts an empty list and rejects incomplete or ambiguous input")
    func scutilFraming() throws {
        let header = "Available network connection services in the current set (*=enabled):"
        #expect(try #require(SCUtilNCParser.parse(header + "\n").value).isEmpty)
        #expect(try #require(SCUtilNCParser.parse(header + "\n\n\n").value).isEmpty)
        let invalid = ["", " \t\n", header, "wrong header\n", header + "\n* (Unknown) 00000000-0000-0000-0000-000000000001 VPN (com.example.vpn) \"Example VPN\" [VPN:com.example.vpn]\n", header + "\n* (Connected) 00000000-0000-0000-0000-000000000001 VPN (com.example.vpn) \"Example VPN\"\n"]
        for text in invalid { #expect(identityFailed(SCUtilNCParser.parse(text))) }
    }

    @Test("scutil parser accepts disconnecting and invalid service states")
    func scutilRemainingStates() throws {
        let fixture = """
        Available network connection services in the current set (*=enabled):
        * (Disconnecting)  00000000-0000-0000-0000-000000000001 VPN (com.example.one) "Example One" [VPN:com.example.one]
        * (Invalid)        00000000-0000-0000-0000-000000000002 VPN (com.example.two) "Example Two" [VPN:com.example.two]

        """
        #expect(try #require(SCUtilNCParser.parse(fixture).value).map(\.state) == [.disconnecting, .invalid])
    }

    @Test("route parser identifies tunnel and physical interfaces")
    func routes() throws {
        for (interface, tunnel) in [("utun7", true), ("ipsec0", true), ("ppp0", true), ("en0", false), ("bridge100", false)] {
            let fixture = "   route to: default\ndestination: default\n       mask: default\n  interface: \(interface)\n      flags: <UP,DONE,CLONING,STATIC,GLOBAL>\n"
            let route = try #require(RouteParser.parse(fixture).value)
            #expect(route.interface == interface)
            #expect(route.isTunnel == tunnel)
        }
        for text in ["", "interface: en0", "route to: default\n", "interface: \n", "interface: en-zero\n", "route: writing to routing socket: not in table\n"] {
            #expect(identityFailed(RouteParser.parse(text)))
        }
    }

    @Test("nwi parser chooses the first physical interface across IPv4 and IPv6")
    func nwiInterfaces() throws {
        let mixed = "Network information\n\nIPv4 network interface information\n   utun7 : flags : 0x5 (IPv4,DNS)\n           address : 192.0.2.10\n     en0 : flags : 0x5 (IPv4,DNS)\n           address : 198.51.100.20\n\nIPv6 network interface information\n   No IPv6 states found\n"
        #expect(try #require(NWIParser.parse(mixed).value) == "en0")
        let ipv6 = "Network information\n\nIPv4 network interface information\n   No IPv4 states found\n\nIPv6 network interface information\n   en1 : flags : 0x5 (IPv6,DNS)\n           address : 2001:db8::1\n"
        #expect(try #require(NWIParser.parse(ipv6).value) == "en1")
        let tunnelOnly = "Network information\n\nIPv4 network interface information\n   utun7 : flags : 0x5 (IPv4,DNS)\n           address : 192.0.2.10\n"
        #expect(identityUnavailableWithReason(NWIParser.parse(tunnelOnly)))
        for text in ["", "Network information", "Network information\n"] {
            #expect(identityFailed(NWIParser.parse(text)))
        }
    }

    @Test("IP trace parser accepts Cloudflare and JSON IPv4 and IPv6 shapes")
    func ipTraceAccepted() throws {
        let cloudflare = try #require(IPTraceParser.parse("fl=1f1\nh=1.1.1.1\nip=198.51.100.7\nts=1.0\nvisit_scheme=https\nloc=RO\ntls=TLSv1.3\n").value)
        #expect(cloudflare == PublicIP(address: "198.51.100.7", country: "RO"))
        #expect(try #require(IPTraceParser.parse("ip=2001:db8::1\nloc=DE\n").value) == PublicIP(address: "2001:db8::1", country: "DE"))
        #expect(try #require(IPTraceParser.parse("ip=203.0.113.9\nloc=ro\n").value).country == nil)
        #expect(try #require(IPTraceParser.parse("ip=203.0.113.9\nloc=Romania\n").value).country == nil)
        #expect(try #require(IPTraceParser.parse("ip=203.0.113.9\n").value).country == nil)
        #expect(try #require(IPTraceParser.parse("{\"ip\":\"203.0.113.9\",\"country\":\"NL\"}").value) == PublicIP(address: "203.0.113.9", country: "NL"))
        #expect(try #require(IPTraceParser.parse("{\"ip\":\"203.0.113.9\"}").value).country == nil)
    }

    @Test("IP trace parser fails closed on malformed, invalid, truncated, and ambiguous bodies")
    func ipTraceRejected() {
        let invalid = ["", " \t\n", "loc=RO\n", "ip=\n", "ip=not-an-ip\n", "ip=999.1.1.1\n", "ip=198.51.100.7:443\n", "ip=198.51.100.7 extra\n", "ip=<script>\n", "ip=198.51.100.7", "ip=198.51.100.7\nip=203.0.113.9\n", "{\"ip\":7}", "{\"ip\":\"999.1.1.1\"}", "[]", "{\"ip\":", "<html>bad</html>"]
        for text in invalid { #expect(identityFailed(IPTraceParser.parse(text)), "Expected failure for \(String(reflecting: text))") }
    }

    @Test("endpoint client accepts supported bodies and rejects HTTP and body failures", arguments: [
        (200, "ip=198.51.100.7\nloc=RO\n", PublicIP(address: "198.51.100.7", country: "RO")),
        (200, "ip=2001:db8::1\nloc=DE\n", PublicIP(address: "2001:db8::1", country: "DE")),
        (200, "{\"ip\":\"203.0.113.9\",\"country\":\"NL\"}", PublicIP(address: "203.0.113.9", country: "NL")),
        (404, "missing", nil), (500, "error", nil), (301, "redirect", nil), (200, "", nil),
        (200, "<html>bad</html>", nil), (200, "ip=not-an-ip\n", nil), (200, "ip=999.1.1.1\n", nil)
    ])
    func endpointResponses(status: Int, body: String, expected: PublicIP?) async throws {
        let server = try IdentityHTTPServer(.response(status, body))
        defer { server.stop() }
        let reading = await IPEndpointClient(endpoint: server.endpoint).fetch(interface: nil, timeout: .seconds(2))
        #expect(reading.value == expected)
        if expected == nil { #expect(identityFailed(reading)) }
    }

    @Test("endpoint client times out and reports connection refusal")
    func endpointTransportFailures() async throws {
        let server = try IdentityHTTPServer(.neverRespond)
        defer { server.stop() }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(identityFailed(await IPEndpointClient(endpoint: server.endpoint).fetch(interface: nil, timeout: .seconds(1))))
        #expect(start.duration(to: clock.now) < .seconds(5))

        let unused = try IdentityHTTPServer(.response(200, "ip=198.51.100.7\n"))
        let refusedEndpoint = unused.endpoint
        unused.stop()
        #expect(identityFailed(await IPEndpointClient(endpoint: refusedEndpoint).fetch(interface: nil, timeout: .seconds(2))))
    }

    @Test("endpoint and interface validation prevent requests")
    func requestValidation() async throws {
        let server = try IdentityHTTPServer(.response(200, "ip=198.51.100.7\n"))
        defer { server.stop() }
        for endpoint in ["file:///etc/hosts", "ftp://example.invalid/", "", "--output=/tmp/x", "-K/etc/passwd"] {
            #expect(identityFailed(await IPEndpointClient(endpoint: endpoint).fetch(interface: nil)))
        }
        for interface in ["en0; touch x", "--proxy", "", "../x"] {
            #expect(identityFailed(await IPEndpointClient(endpoint: server.endpoint).fetch(interface: interface)))
        }
        #expect(server.requestCount == 0)
        let loopback = await IPEndpointClient(endpoint: server.endpoint).fetch(interface: "lo0", timeout: .seconds(2))
        #expect(loopback.isOK)
        #expect(server.requestCount == 1)
        #expect(IPEndpointClient.defaultEndpoint == "https://1.1.1.1/cdn-cgi/trace")
    }

    @Test("disabled collector performs no IP request and returns the off contract")
    func disabledCollector() async throws {
        let server = try IdentityHTTPServer(.response(200, "ip=198.51.100.7\nloc=RO\n"))
        defer { server.stop() }
        let identity = await NetworkIdentityCollector(client: IPEndpointClient(endpoint: server.endpoint)).collect(checkEnabled: false)
        #expect(identityUnavailableWithReason(identity.publicIP))
        #expect(identityUnavailableWithReason(identity.ispIP))
        #expect(identity.verdict == .off)
        #expect(server.requestCount == 0)
        _ = identity.vpnServices
        _ = identity.defaultRoute
        _ = identity.physicalInterface
    }

    @Test("enabled collector requests locally and fails closed when an IP is unknown")
    func enabledCollector() async throws {
        let server = try IdentityHTTPServer(.response(200, "ip=198.51.100.7\nloc=RO\n"))
        defer { server.stop() }
        let identity = await NetworkIdentityCollector(client: IPEndpointClient(endpoint: server.endpoint)).collect(checkEnabled: true)
        #expect(server.requestCount >= 1)
        #expect(LeakVerdict.allCasesForAcceptance.contains(identity.verdict))
        if !identity.publicIP.isOK || !identity.ispIP.isOK { #expect(identity.verdict == .unknown) }
        if !identity.physicalInterface.isOK { #expect(!identity.ispIP.isOK && identity.verdict == .unknown) }
    }
}

private extension LeakVerdict {
    static let allCasesForAcceptance: [LeakVerdict] = [.off, .unknown, .noVPN, .leak, .splitTunnel, .tunnelOK]
}
