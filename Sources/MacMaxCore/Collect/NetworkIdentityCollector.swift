import Foundation

/// VPN services, the default route, the physical interface, the public IP and the ISP IP, and the verdict
/// they give. Each system tool is read once per call; a tool that cannot run is `failed`, never absent.
public actor NetworkIdentityCollector {
    private let client: IPEndpointClient

    public init(client: IPEndpointClient = IPEndpointClient()) { self.client = client }

    /// `checkEnabled` false: no request is made and the verdict is `off`.
    public func collect(checkEnabled: Bool) async -> NetworkIdentity {
        async let services = read("/usr/sbin/scutil", ["--nc", "list"], parse: SCUtilNCParser.parse)
        async let route = read("/sbin/route", ["-n", "get", "default"], parse: RouteParser.parse)
        async let physical = read("/usr/sbin/scutil", ["--nwi"], parse: NWIParser.parse)
        let (listedServices, defaultRoute, physicalInterface) = await (services, route, physical)
        let vpnServices = await withTunnels(listedServices)

        var publicIP: Reading<PublicIP> = .unavailable(reason: "the IP check is off")
        var ispIP = publicIP
        if checkEnabled {
            async let viaDefault = client.fetch(interface: nil)
            async let viaPhysical = ispReading(physicalInterface)
            (publicIP, ispIP) = await (viaDefault, viaPhysical)
        }
        let verdict = LeakVerdictEngine.verdict(checkEnabled: checkEnabled, vpnServices: vpnServices, route: defaultRoute,
                                                publicIP: publicIP, ispIP: ispIP)
        return NetworkIdentity(vpnServices: vpnServices, defaultRoute: defaultRoute, physicalInterface: physicalInterface,
                               publicIP: publicIP, ispIP: ispIP, verdict: verdict)
    }

    /// Asks each connected service which tunnel interface it owns, so the route can be matched to one VPN. A service that
    /// cannot be asked keeps no tunnel: the route then matches none of them and no VPN is named.
    private func withTunnels(_ reading: Reading<[VPNService]>) async -> Reading<[VPNService]> {
        guard case let .ok(services, source, at) = reading else { return reading }
        var result = services
        let asked = result.indices.filter { result[$0].state == .connected && result[$0].serviceID != nil }
        // All at once: one hung service costs one timeout, not one per service.
        let tunnels = await withTaskGroup(of: (Int, String?).self) { group in
            for index in asked {
                let id = result[index].serviceID!
                group.addTask {
                    guard let output = try? await ProcessRunner().run("/usr/sbin/scutil", ["--nc", "status", id], timeout: .seconds(3)),
                          output.status == 0 else { return (index, nil) }
                    return (index, SCUtilNCStatusParser.tunnelInterface(String(decoding: output.stdout, as: UTF8.self)))
                }
            }
            var found: [Int: String] = [:]
            for await (index, tunnel) in group { if let tunnel { found[index] = tunnel } }
            return found
        }
        for (index, tunnel) in tunnels { result[index].tunnel = tunnel }
        return .ok(result, source: source, at: at)
    }

    private func ispReading(_ physical: Reading<String>) async -> Reading<PublicIP> {
        switch physical {
        case let .ok(interface, _, _): await client.fetch(interface: interface)
        case let .unavailable(reason): .unavailable(reason: reason)
        case let .failed(reason): .failed(reason: reason)
        }
    }

    private func read<T: Sendable>(_ executable: String, _ arguments: [String],
                                   parse: (String, Date) -> Reading<T>) async -> Reading<T> {
        do {
            let output = try await ProcessRunner().run(executable, arguments, timeout: .seconds(5))
            guard output.status == 0 else { return .failed(reason: "\(executable) exited with status \(output.status)") }
            return parse(String(decoding: output.stdout, as: UTF8.self), Date())
        } catch {
            return .failed(reason: "\(executable) did not finish: \(error.localizedDescription)")
        }
    }
}
