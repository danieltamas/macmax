import Foundation
import SystemConfiguration

/// What a kernel interface name means to the person reading it: "en0" is Wi-Fi, "utun7" is a VPN tunnel.
enum InterfaceNaming {
    /// The names System Settings uses for the interfaces it manages (en0 is "Wi-Fi"), read once.
    private static let system: [String: String] = {
        var names: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let title = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsd] = title
        }
        return names
    }()

    private static let prefixes: [(prefix: String, title: String)] = [
        ("utun", "VPN or system tunnel"), ("bridge100", "Shared network (Internet Sharing, VMs)"), ("bridge", "Bridge"),
        ("awdl", "AirDrop and Handoff (Wi-Fi Direct)"), ("llw", "Low-latency Wi-Fi (AirPlay, Continuity)"),
        ("anpi", "Internal network processor"), ("ap", "Personal Hotspot"), ("gif", "IPv6 tunnel (unused)"),
        ("stf", "IPv6 tunnel (unused)"), ("lo", "Loopback"), ("en", "Network port"),
    ]

    static func title(_ bsd: String) -> String {
        if let name = system[bsd] { return name }
        return prefixes.first { bsd.hasPrefix($0.prefix) }?.title ?? bsd
    }
}
