import Foundation

/// Asks an IP endpoint what the internet sees, through `/usr/bin/curl` (it can bind an interface).
public struct IPEndpointClient: Sendable {
    public static let defaultEndpoint = "https://1.1.1.1/cdn-cgi/trace"
    private static let curl = "/usr/bin/curl"
    private static let maxBodyBytes = 65_536

    public let endpoint: String

    public init(endpoint: String = IPEndpointClient.defaultEndpoint) { self.endpoint = endpoint }

    /// `interface` binds the request to that interface (the ISP IP); nil uses the default route.
    public func fetch(interface: String?, timeout: Duration = .seconds(10)) async -> Reading<PublicIP> {
        guard isHTTPURL(endpoint) else { return .failed(reason: "the IP endpoint is not an http or https URL") }
        if let interface, !isInterfaceName(interface) { return .failed(reason: "not a network interface name") }
        let seconds = max(1, Int(timeout.components.seconds) + (timeout.components.attoseconds > 0 ? 1 : 0))
        var arguments = ["-sS", "--connect-timeout", "5", "--max-time", String(seconds), "--proto", "=http,https",
                         "--max-filesize", String(Self.maxBodyBytes), "-w", "\n%{http_code}"]
        if let interface { arguments += ["--interface", interface] }
        // `--` ends the options, so an endpoint can never be read as a flag.
        arguments += ["--", endpoint]
        let output: ProcessOutput
        do {
            output = try await ProcessRunner().run(Self.curl, arguments, timeout: timeout + .seconds(3))
        } catch {
            return .failed(reason: "the IP check did not finish: \(error.localizedDescription)")
        }
        guard output.status == 0 else { return .failed(reason: "the IP check failed (curl exit \(output.status))") }
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard let split = text.lastIndex(of: "\n") else { return .failed(reason: "the IP check answered nothing") }
        let status = text[text.index(after: split)...]
        guard status == "200" else { return .failed(reason: "the IP endpoint answered HTTP \(status)") }
        return IPTraceParser.parse(String(text[...split]))
    }

    private func isHTTPURL(_ text: String) -> Bool {
        (text.hasPrefix("http://") || text.hasPrefix("https://"))
            && !text.contains { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains { $0.value < 0x20 } }
    }
}
