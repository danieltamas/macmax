import Foundation

/// The leak verdict table of docs/NETWORK.md, first match wins. A reading that is not `ok` is unknown,
/// never healthy.
public enum LeakVerdictEngine {
    public static func verdict(checkEnabled: Bool, vpnServices: Reading<[VPNService]>, route: Reading<DefaultRoute>,
                               publicIP: Reading<PublicIP>, ispIP: Reading<PublicIP>) -> LeakVerdict {
        guard checkEnabled else { return .off }
        guard let services = vpnServices.value, let route = route.value,
              let publicIP = publicIP.value, let ispIP = ispIP.value else { return .unknown }
        let inUse = route.isTunnel || services.contains { $0.state == .connected }
        guard inUse else { return .noVPN }
        // An address that is not a literal cannot be compared, so it is unknown, not "different".
        guard let publicBytes = ipBytes(publicIP.address), let ispBytes = ipBytes(ispIP.address) else { return .unknown }
        if publicBytes == ispBytes { return .leak }
        return route.isTunnel ? .tunnelOK : .splitTunnel
    }
}
