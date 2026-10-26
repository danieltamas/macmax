import MacMaxCore
import SwiftUI

/// The opened row of a background item: who added it, what it runs, when, and where it is connected right now.
struct StartupDetailView: View {
    let item: StartupItem
    let inspection: StartupInspection?
    let isReading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isReading { OperationProgress(text: "Reading the details...") }
            // Once the plist has been read again it is the truth: a program from the older scan may no longer be there.
            let current = inspection == nil ? item : StartupItem(label: item.label, path: item.path, scope: item.scope, program: inspection?.detail?.program, runsAtLoad: false)
            let owner = StartupOwnerGuess.owner(of: current, detail: inspection?.detail)
            block("Added by", owner.appName.map { Redaction.sanitizeText($0) } ?? "Unknown", note: Redaction.sanitizeText(owner.note))
            if let program = current.program {
                block("Runs", Self.display(program), note: Self.arguments(inspection?.detail), mono: true)
            }
            if inspection?.detail != nil || !isReading {
                block("Starts", Self.when(item, inspection?.detail), note: inspection?.detail == nil ? "The property list could not be read again, so the schedule is not known." : nil)
            }
            network
            block("Defined in", Self.display(item.path), note: Self.scopeNote(item.scope), mono: true)
        }
        .padding(.leading, 10).padding(.vertical, 6)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 2) }
    }

    @ViewBuilder private var network: some View {
        if isReading {
            EmptyView()
        } else if inspection?.isRunning == nil {
            block("Network", "Could not be read", note: "The system did not say whether it is running, so MacMax does not claim there are none.")
        } else if inspection?.isRunning == false {
            block("Network", "Not running now", note: "Nothing is connected. Open this again while it runs to see where it connects.")
        } else if let connections = inspection?.connections {
            let outbound = connections.filter(\.isOutbound), listening = connections.filter { !$0.isOutbound }
            VStack(alignment: .leading, spacing: 3) {
                label("Network right now")
                if connections.isEmpty { value("No open connections") }
                ForEach(Array(outbound.enumerated()), id: \.offset) { _, connection in
                    value("\(Self.kind(connection.remoteAddress ?? "")): \(connection.remoteAddress ?? ""):\(connection.remotePort ?? "") (\(connection.transport == .tcp ? "TCP" : "UDP")\(connection.state.map { ", \($0.lowercased())" } ?? ""))", mono: true)
                }
                if !listening.isEmpty { value("Waiting for connections on \(listening.count) port\(listening.count == 1 ? "" : "s")") }
                note("MacMax sees which addresses it is connected to at this moment, not what is sent. A program that talks only now and then may show nothing.")
            }
        } else {
            block("Network", "Could not be read", note: "The system did not answer, so MacMax does not claim there are none.")
        }
    }

    private func block(_ title: String, _ text: String, note text2: String?, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title)
            value(text, mono: mono)
            if let text2, !text2.isEmpty { note(text2) }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
    }

    private func value(_ text: String, mono: Bool = false) -> some View {
        Text(text).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 12)).foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private static func display(_ text: String) -> String {
        // Invisible characters go first: one inside `--api-key` would otherwise hide the flag from the redaction.
        let shown = Redaction.redact([Redaction.sanitizeText(text)]).joined(separator: " ")
        let home = NSHomeDirectory()
        return shown.hasPrefix(home) ? "~" + shown.dropFirst(home.count) : shown
    }

    /// The arguments after the program, redacted: a token on a command line must not be shown.
    private static func arguments(_ detail: StartupDetail?) -> String? {
        guard let detail, detail.arguments.count > 1 else { return nil }
        return "Arguments: " + Redaction.redact(detail.arguments.dropFirst().map(Redaction.sanitizeText)).joined(separator: " ")
    }

    private static func when(_ item: StartupItem, _ detail: StartupDetail?) -> String {
        guard detail != nil else { return "Unknown" }
        var parts: [String] = []
        if detail?.keepAlive == true { parts.append("kept alive by macOS (restarted when it stops)") }
        else if detail?.runAtLoad == true { parts.append("at login or startup") }
        if let seconds = detail?.startIntervalSeconds {
            parts.append(seconds % 3600 == 0 ? "every \(seconds / 3600) h" : seconds % 60 == 0 ? "every \(seconds / 60) min" : "every \(seconds) s")
        }
        if detail?.hasCalendarSchedule == true { parts.append("on a schedule") }
        if let paths = detail?.watchPaths, !paths.isEmpty { parts.append("when a watched folder changes") }
        return parts.isEmpty ? "Only when something asks for it" : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
    }

    private static func scopeNote(_ scope: StartupScope) -> String {
        switch scope {
        case .userAgent: "Your own Launch Agents folder: runs as you. You can turn it off here."
        case .globalAgent: "Installed for every user, runs as the user who logs in. Changing it needs an administrator."
        case .globalDaemon: "Installed for the whole Mac, runs even before anyone logs in. Changing it needs an administrator."
        }
    }

    /// Where an address points, in words: this Mac, the local network, or the Internet.
    static func kind(_ address: String) -> String {
        if address == "::1" || address.hasPrefix("127.") { return "This Mac" }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) { return "Local network" }
            return "Internet"
        }
        let lower = address.lowercased()
        if lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd") { return "Local network" }
        return "Internet"
    }
}
