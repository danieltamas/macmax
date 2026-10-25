import Darwin
import Foundation

private let interfaceName = try! NSRegularExpression(pattern: #"^[a-z]+[0-9]+$"#)

func isInterfaceName(_ text: String) -> Bool {
    interfaceName.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

func isTunnelInterface(_ name: String) -> Bool {
    ["utun", "ipsec", "ppp"].contains { name.hasPrefix($0) }
}

/// A strict IPv4 or IPv6 literal (no port, zone, spaces or hostnames).
func isIPLiteral(_ text: String) -> Bool { ipBytes(text) != nil }

/// The 4 or 16 bytes of an IP literal, so `2001:db8::1` and `2001:0db8:0:0:0:0:0:1` compare equal.
func ipBytes(_ text: String) -> [UInt8]? {
    // inet_pton reads a C string: a NUL would hide trailing junk from it.
    guard !text.utf8.contains(0) else { return nil }
    var v4 = in_addr(), v6 = in6_addr()
    if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
    if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
    return nil
}

/// `scutil --nc list`. A line is `* (State) UUID VPN (bundle.id) "name" [VPN:bundle.id]`; the name can hold
/// quotes, so it is everything between the first quote and the last quote before the bracket.
public enum SCUtilNCParser {
    private static let line = try! NSRegularExpression(
        pattern: #"^\s*\*?\s*\((\w+)\)\s+[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\s+VPN\s+\(([^)]+)\)\s+"(.*)"\s+\[VPN:\2\]\s*$"#)
    /// A well-formed line of another connection type (`... PPP --> en0 "x" [PPP:L2TP]`), not a Network Extension VPN.
    private static let otherType = try! NSRegularExpression(
        pattern: #"^\s*\*?\s*\(\w+\)\s+[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\s+(PPP|IPSec)\b.*\[\1:[^\]]+\]\s*$"#)
    private static let labels = [
        "org.outline.macos.client": "Outline", "io.tailscale.ipn.macsys": "Tailscale", "io.tailscale.ipn.macos": "Tailscale",
        "com.wireguard.macos": "WireGuard", "net.mullvad.vpn": "Mullvad", "ch.protonvpn.mac": "ProtonVPN",
    ]
    private static let states: [String: VPNState] = [
        "Connected": .connected, "Disconnected": .disconnected, "Connecting": .connecting,
        "Disconnecting": .disconnecting, "Invalid": .invalid,
    ]

    public static func parse(_ text: String, at: Date = .now) -> Reading<[VPNService]> {
        let lines: [Substring]
        switch ParserSupport.lines(text, tool: "scutil --nc list") {
        case let .success(parsed): lines = parsed.filter { !$0.allSatisfy(\.isWhitespace) }
        case let .failure(failure): return .failed(reason: failure.reason)
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "Available network connection services in the current set (*=enabled):" else {
            return .failed(reason: "scutil --nc list header is missing")
        }
        var services: [VPNService] = []
        for line in lines.dropFirst() {
            let text = String(line)
            guard let match = Self.line.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                // Other connection types (PPP, IPSec) are not Network Extension VPNs; a line with no type is unreadable.
                if otherType.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { continue }
                return .failed(reason: "a scutil --nc list line is not understood")
            }
            func group(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]) }
            guard let state = states[group(1)] else { return .failed(reason: "a VPN service has an unknown state") }
            let bundle = group(2), name = group(3)
            services.append(VPNService(name: name, bundleID: bundle, state: state, label: labels[bundle] ?? name))
        }
        return .ok(services, source: "scutil --nc list", at: at)
    }
}

/// `route -n get default`.
public enum RouteParser {
    public static func parse(_ text: String, at: Date = .now) -> Reading<DefaultRoute> {
        guard text.hasSuffix("\n") else { return .failed(reason: "route output is empty or cut off") }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface:") else { continue }
            let name = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            guard isInterfaceName(name) else { return .failed(reason: "the default route names no interface") }
            return .ok(DefaultRoute(interface: name, isTunnel: isTunnelInterface(name)), source: "route -n get default", at: at)
        }
        return .failed(reason: "there is no default route")
    }
}

/// `scutil --nwi`: the first non-tunnel interface in the service order.
public enum NWIParser {
    private static let entry = try! NSRegularExpression(pattern: #"^\s+([a-z]+[0-9]+) : flags"#)

    public static func parse(_ text: String, at: Date = .now) -> Reading<String> {
        let lines: [Substring]
        switch ParserSupport.lines(text, tool: "scutil --nwi") {
        case let .success(parsed): lines = parsed
        case let .failure(failure): return .failed(reason: failure.reason)
        }
        var sawSection = false
        var candidates: [String] = []
        for line in lines {
            if line.contains("network interface information") { sawSection = true; continue }
            let text = String(line)
            if let match = entry.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                candidates.append(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        guard sawSection else { return .failed(reason: "scutil --nwi has no interface section") }
        guard let physical = candidates.first(where: { !isTunnelInterface($0) && !$0.hasPrefix("lo") }) else {
            return .unavailable(reason: "no physical network interface is up")
        }
        return .ok(physical, source: "scutil --nwi", at: at)
    }
}

/// The body of an IP endpoint: Cloudflare `key=value` lines, or JSON with `ip` and `country`.
public enum IPTraceParser {
    public static func parse(_ text: String, at: Date = .now) -> Reading<PublicIP> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(reason: "the IP endpoint answered with nothing") }
        return trimmed.hasPrefix("{") ? json(trimmed, at: at) : keyValue(text, at: at)
    }

    private static func country(_ code: String?) -> String? {
        guard let code, code.count == 2, code.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return code
    }

    private static func json(_ text: String, at: Date) -> Reading<PublicIP> {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let address = object["ip"] as? String, isIPLiteral(address) else {
            return .failed(reason: "the IP endpoint answered with JSON that has no valid ip")
        }
        return .ok(PublicIP(address: address, country: country(object["country"] as? String)), source: "ip endpoint", at: at)
    }

    private static func keyValue(_ text: String, at: Date) -> Reading<PublicIP> {
        guard text.hasSuffix("\n") else { return .failed(reason: "the IP endpoint answer is cut off") }
        var addresses: [String] = [], locations: [String] = []
        for line in text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("ip=") { addresses.append(String(line.dropFirst(3))) }
            if line.hasPrefix("loc=") { locations.append(String(line.dropFirst(4))) }
        }
        guard addresses.count == 1, isIPLiteral(addresses[0]) else {
            return .failed(reason: "the IP endpoint answer has no single valid ip= line")
        }
        return .ok(PublicIP(address: addresses[0], country: locations.count == 1 ? country(locations[0]) : nil),
                   source: "ip endpoint", at: at)
    }
}
