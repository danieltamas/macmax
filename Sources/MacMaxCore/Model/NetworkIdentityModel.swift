import Foundation

public enum VPNState: String, Sendable, Equatable {
    case connected, disconnected, connecting, disconnecting, invalid
}

/// One Network Extension VPN service from `scutil --nc list`.
public struct VPNService: Sendable, Equatable {
    public let name: String
    public let bundleID: String
    public let state: VPNState
    /// A friendly label for known providers (Outline, Tailscale, ...), else the quoted name.
    public let label: String

    public init(name: String, bundleID: String, state: VPNState, label: String) {
        self.name = name
        self.bundleID = bundleID
        self.state = state
        self.label = label
    }
}

/// The interface the default route leaves through.
public struct DefaultRoute: Sendable, Equatable {
    public let interface: String
    /// `utun*`, `ipsec*`, `ppp*`.
    public let isTunnel: Bool

    public init(interface: String, isTunnel: Bool) {
        self.interface = interface
        self.isTunnel = isTunnel
    }
}

/// What an IP endpoint says the internet sees: a validated IPv4 or IPv6 literal and, when given, a country.
public struct PublicIP: Sendable, Equatable {
    public let address: String
    public let country: String?

    public init(address: String, country: String?) {
        self.address = address
        self.country = country
    }
}

public enum LeakVerdict: String, Sendable, Equatable {
    case off, unknown, noVPN = "no_vpn", leak, splitTunnel = "split_tunnel", tunnelOK = "tunnel_ok"
}

/// Everything the Network tab and the vpn_leak rule need about this Mac's network identity.
public struct NetworkIdentity: Sendable {
    public let vpnServices: Reading<[VPNService]>
    public let defaultRoute: Reading<DefaultRoute>
    /// The first non-tunnel interface in the system's service order (`en0` on most Macs).
    public let physicalInterface: Reading<String>
    public let publicIP: Reading<PublicIP>
    public let ispIP: Reading<PublicIP>
    public let verdict: LeakVerdict

    public init(vpnServices: Reading<[VPNService]>, defaultRoute: Reading<DefaultRoute>,
                physicalInterface: Reading<String>, publicIP: Reading<PublicIP>, ispIP: Reading<PublicIP>,
                verdict: LeakVerdict) {
        self.vpnServices = vpnServices
        self.defaultRoute = defaultRoute
        self.physicalInterface = physicalInterface
        self.publicIP = publicIP
        self.ispIP = ispIP
        self.verdict = verdict
    }
}
