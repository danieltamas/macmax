import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MacMaxCore

private func runNetworkIdentityCommand(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}

private func liveIdentityFailed<T>(_ reading: Reading<T>) -> Bool {
    if case .failed = reading { return true }
    return false
}

private func validIPLiteral(_ text: String) -> Bool {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    return text.withCString {
        inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
    }
}

private func hashPrefix(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
}

@Suite(
    "NetworkIdentityLiveAcceptance",
    .enabled(if: ProcessInfo.processInfo.environment["MACMAX_LIVE"] == "1")
)
struct NetworkIdentityLiveAcceptanceTests {
    @Test("real network identity command outputs satisfy parser framing")
    func realParsers() throws {
        let services = SCUtilNCParser.parse(try runNetworkIdentityCommand("/usr/sbin/scutil", ["--nc", "list"]))
        let parsedServices = try #require(services.value)
        #expect(parsedServices.allSatisfy { !$0.bundleID.isEmpty && !$0.name.isEmpty })

        let routeText = try runNetworkIdentityCommand("/sbin/route", ["-n", "get", "default"])
        let route = RouteParser.parse(routeText)
        if route.value == nil {
            #expect(routeText.contains("not in table"), "Route parsing may fail only when there is no default route")
        }

        let physical = NWIParser.parse(try runNetworkIdentityCommand("/usr/sbin/scutil", ["--nwi"]))
        #expect(!liveIdentityFailed(physical))
    }

    @Test("live collector returns valid IPs and never prints them")
    func liveCollector() async throws {
        let identity = await NetworkIdentityCollector().collect(checkEnabled: true)
        let publicIP = try #require(identity.publicIP.value)
        #expect(validIPLiteral(publicIP.address))
        print("public_ip_sha256=\(hashPrefix(publicIP.address))")

        let connected = identity.vpnServices.value?.contains { $0.state == .connected } == true
        if connected {
            let ispIP = try #require(identity.ispIP.value)
            #expect(validIPLiteral(ispIP.address))
            print("isp_ip_sha256=\(hashPrefix(ispIP.address))")
        } else if let ispIP = identity.ispIP.value {
            #expect(validIPLiteral(ispIP.address))
            print("isp_ip_sha256=\(hashPrefix(ispIP.address))")
        }
        #expect(identity.verdict != .off)
    }
}
