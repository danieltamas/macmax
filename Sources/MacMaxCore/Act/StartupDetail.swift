import Foundation

/// What a launchd property list says about when and how it runs, for the detail view of a background item.
public struct StartupDetail: Sendable, Equatable {
    public let program: String?
    public let arguments: [String]
    public let associatedBundleIDs: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let startIntervalSeconds: Int?
    public let hasCalendarSchedule: Bool
    public let watchPaths: [String]
    public let workingDirectory: String?
    public let standardOutPath: String?
    public let standardErrorPath: String?
    /// Names only: a value in the environment can be a token.
    public let environmentKeys: [String]
    public let userName: String?

    public init(program: String?, arguments: [String] = [], associatedBundleIDs: [String] = [], runAtLoad: Bool = false, keepAlive: Bool = false,
                startIntervalSeconds: Int? = nil, hasCalendarSchedule: Bool = false, watchPaths: [String] = [], workingDirectory: String? = nil,
                standardOutPath: String? = nil, standardErrorPath: String? = nil, environmentKeys: [String] = [], userName: String? = nil) {
        self.program = program
        self.arguments = arguments
        self.associatedBundleIDs = associatedBundleIDs
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.startIntervalSeconds = startIntervalSeconds
        self.hasCalendarSchedule = hasCalendarSchedule
        self.watchPaths = watchPaths
        self.workingDirectory = workingDirectory
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
        self.environmentKeys = environmentKeys
        self.userName = userName
    }
}

public enum StartupDetailParser {
    public static func parse(_ plist: Data) -> Reading<StartupDetail> {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
              let plistDictionary = object as? [String: Any]
        else { return .failed(reason: "The property list could not be read.") }
        func strings(_ key: String) -> [String] { (plistDictionary[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
        let arguments = strings("ProgramArguments")
        let keepAlive = plistDictionary["KeepAlive"]
        // A plist boolean reads as the number 1: it is not an interval.
        let interval = (plistDictionary["StartInterval"] as? NSNumber).flatMap { number in
            CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : (number as? Int).flatMap { $0 > 0 ? $0 : nil }
        }
        // A Program that is not a string is invalid: it does not fall back to the arguments.
        let program = plistDictionary["Program"].map { $0 as? String } ?? (plistDictionary["ProgramArguments"] as? [Any])?.first as? String
        let associated = (plistDictionary["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? strings("AssociatedBundleIdentifiers")
        let calendar = plistDictionary["StartCalendarInterval"]
        let detail = StartupDetail(
            program: program, arguments: arguments,
            associatedBundleIDs: associated,
            runAtLoad: (plistDictionary["RunAtLoad"] as? Bool) == true,
            keepAlive: (keepAlive as? Bool) == true || keepAlive is [String: Any],
            startIntervalSeconds: interval,
            hasCalendarSchedule: calendar is [String: Any] || ((calendar as? [Any])?.isEmpty == false),
            watchPaths: strings("WatchPaths") + strings("QueueDirectories"),
            workingDirectory: plistDictionary["WorkingDirectory"] as? String,
            standardOutPath: plistDictionary["StandardOutPath"] as? String,
            standardErrorPath: plistDictionary["StandardErrorPath"] as? String,
            environmentKeys: ((plistDictionary["EnvironmentVariables"] as? [String: Any]) ?? [:]).keys.sorted(),
            userName: plistDictionary["UserName"] as? String)
        return .ok(detail, source: "plist", at: Date())
    }
}

/// One TCP or UDP socket of a process, as `lsof -i` shows it.
public struct ProcessConnection: Sendable, Equatable {
    public enum Transport: Sendable, Equatable { case tcp, udp }
    public let transport: Transport
    public let localAddress: String
    public let localPort: String
    public let remoteAddress: String?
    public let remotePort: String?
    public let state: String?
    public var isOutbound: Bool { remoteAddress != nil }

    public init(transport: Transport, localAddress: String, localPort: String, remoteAddress: String? = nil, remotePort: String? = nil, state: String? = nil) {
        self.transport = transport
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
    }
}

public enum LsofConnections {
    /// Like `parse`, but nil when a line of the answer could not be understood: a partial list must not read as the
    /// whole one.
    public static func parseAll(_ text: String) -> [ProcessConnection]? {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("COMMAND") && !$0.allSatisfy(\.isWhitespace) }
        let connections = parse(text)
        return connections.count == lines.count ? connections : nil
    }

    public static func parse(_ text: String) -> [ProcessConnection] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let nodeIndex = columns.firstIndex(where: { $0 == "TCP" || $0 == "UDP" }), nodeIndex + 1 < columns.count else { return nil }
            let name = columns[(nodeIndex + 1)...].joined(separator: " ")
            var endpoints = name
            var state: String?
            if let open = name.lastIndex(of: "("), name.hasSuffix(")") {
                state = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
                endpoints = name[..<open].trimmingCharacters(in: .whitespaces)
            }
            let ends = endpoints.components(separatedBy: "->")
            guard ends.count <= 2, let local = split(ends[0]) else { return nil }
            let remote = ends.count == 2 ? split(ends[1]) : nil
            if ends.count == 2, remote == nil { return nil }
            return ProcessConnection(transport: columns[nodeIndex] == "TCP" ? .tcp : .udp, localAddress: local.host, localPort: local.port,
                                     remoteAddress: remote?.host, remotePort: remote?.port, state: state)
        }
    }

    /// `host:port`, `[v6]:port` or `*:port`.
    private static func split(_ end: String) -> (host: String, port: String)? {
        guard let colon = end.lastIndex(of: ":") else { return nil }
        var host = String(end[..<colon])
        let port = String(end[end.index(after: colon)...])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty || port.isEmpty ? nil : (host, port)
    }
}

/// Who most likely added a background item, and how sure that is.
public struct StartupOwner: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case appBundle, associatedBundle, labelVendor, unknown }
    public let source: Source
    public let appName: String?
    public let appPath: String?
    public let note: String
}

public enum StartupOwnerGuess {
    private static let topLevel: Set<String> = ["com", "org", "net", "io", "ro", "eu", "app", "co"]

    public static func owner(of item: StartupItem, detail: StartupDetail?) -> StartupOwner {
        if let program = item.program ?? detail?.program, program.hasPrefix("/") {
            let parts = program.split(separator: "/", omittingEmptySubsequences: true)
            if let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
                let folder = String(parts[index])
                return StartupOwner(source: .appBundle, appName: String(folder.dropLast(4)),
                                    appPath: "/" + parts[...index].joined(separator: "/"),
                                    note: "Its program lives inside the app \(folder).")
            }
        }
        if let bundle = detail?.associatedBundleIDs.first {
            return StartupOwner(source: .associatedBundle, appName: bundle, appPath: nil,
                                note: "Its property list names \(bundle) as the app it belongs to.")
        }
        let parts = item.label.split(separator: ".").map(String.init)
        if parts.count >= 3, topLevel.contains(parts[0].lowercased()) {
            let vendor = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
            return StartupOwner(source: .labelVendor, appName: vendor, appPath: nil,
                                note: "A guess from the name: it looks like it comes from \(vendor). MacMax cannot confirm that.")
        }
        return StartupOwner(source: .unknown, appName: nil, appPath: nil, note: "MacMax cannot tell which app added this.")
    }
}
