import Foundation
import MacMaxCore

/// Turns store rows and collector readings into the plain values the views show. Pure, so the live controller and
/// the screenshots share it and nothing here reads the Mac.
enum PanelData {
    static func vital(forRule id: String) -> Vital.Kind? {
        switch id {
        case "cpu_idle", "kernel_cpu": .cpu
        case "compressor", "memory_level", "docker_vm_compressed": .memory
        case "swap_used", "swap_in_rate": .swap
        case "disk_free", "disk_iops": .disk
        default: nil
        }
    }

    /// `row` nil keeps the previous values and only refreshes the edges (an audit landed between ticks).
    static func vitals(_ row: SystemSampleRow?, series: [Vital.Kind: [Double]], edges: [Vital.Kind: Severity],
                       keeping previous: [Vital] = []) -> [Vital] {
        guard let row else {
            return previous.map { var vital = $0; vital.edge = edges[vital.kind]; return vital }
        }
        func make(_ kind: Vital.Kind, _ value: String?, _ detail: String) -> Vital {
            Vital(kind: kind, value: value ?? "-", detail: value == nil ? "not measured" : detail, series: series[kind] ?? [],
                  edge: edges[kind])
        }
        let cpu = row.cpuUser.flatMap { user in row.cpuSystem.map { user + $0 } }
        let pressure = row.pressureLevel.flatMap(MemoryPressureLevel.init(rawValue:)).map { level -> String in
            switch level {
            case .normal: "Normal"
            case .warning: "Warning"
            case .critical: "Critical"
            }
        }
        return [
            make(.cpu, cpu.map { CompactFormat.percent($0) }, "busy"),
            make(.memory, pressure, row.memUsed.map { "\(CompactFormat.bytes(UInt64(max($0, 0)))) used" } ?? "pressure"),
            make(.swap, row.swapUsed.map { CompactFormat.bytes(UInt64(max($0, 0))) }, "in use"),
            make(.disk, row.diskFree.map { CompactFormat.bytes(UInt64(max($0, 0))) }, "free"),
            make(.netIn, row.netInBps.map(CompactFormat.rate), "right now"),
            make(.netOut, row.netOutBps.map(CompactFormat.rate), "right now"),
        ]
    }

    static func appRow(_ row: AppSampleRow, name: String?, interval: Double, pids: [Int32] = []) -> AppRow {
        func rate(_ bytes: Int64?) -> Double? { bytes.map { Double(max($0, 0)) / max(interval, 1) } }
        let networkIn = rate(row.netInBytes)
        let networkOut = rate(row.netOutBytes)
        let network: Double? = (networkIn == nil && networkOut == nil) ? nil : (networkIn ?? 0) + (networkOut ?? 0)
        let disk: Double? = (row.diskReadBps == nil && row.diskWriteBps == nil) ? nil : (row.diskReadBps ?? 0) + (row.diskWriteBps ?? 0)
        let shown = name ?? row.appKey
        return AppRow(id: row.appKey, name: shown, bundleID: row.appKey.contains("/") ? nil : row.appKey,
                      kind: kind(key: row.appKey, name: shown), pids: pids, processCount: row.procs, cpuPercent: row.cpu,
                      footprintBytes: row.footprint.map { UInt64(max($0, 0)) }, diskBytesPerSecond: disk,
                      networkBytesPerSecond: network)
    }

    static func kind(key: String, name: String) -> AppKind {
        let lowered = name.lowercased()
        if lowered.contains("docker") || key.lowercased().contains("docker") { return .docker }
        if lowered == "claude" || lowered == "claude code" { return .claudeCode }
        return key.hasSuffix(".app") || key.contains(".") && !key.contains("/") ? .app : .background
    }

    static func processes(_ rows: [ProcSampleRow]) -> [String: [ProcessLine]] {
        Dictionary(grouping: rows, by: \.appKey).mapValues { group in
            group.sorted { ($1.cpu ?? -1, $0.pid) < ($0.cpu ?? -1, $1.pid) }.map {
                ProcessLine(pid: $0.pid, name: $0.name, cpuPercent: $0.cpu, footprintBytes: $0.footprint.map { UInt64(max($0, 0)) },
                            isTranslated: false, commandLine: nil, startUs: $0.startUs)
            }
        }
    }

    static func topConsumers(_ apps: [AppRow]) -> [(label: String, app: String, value: String)] {
        var result: [(label: String, app: String, value: String)] = []
        if let top = AppListing.sorted(apps, by: .cpu).first, let cpu = top.cpuPercent {
            result.append(("CPU", top.name, CompactFormat.percent(cpu)))
        }
        if let top = AppListing.sorted(apps, by: .memory).first, let bytes = top.footprintBytes {
            result.append(("Memory", top.name, CompactFormat.bytes(bytes)))
        }
        if let top = AppListing.sorted(apps, by: .network).first, let rate = top.networkBytesPerSecond {
            result.append(("Network", top.name, CompactFormat.rate(rate)))
        }
        return result
    }

    static func interfaces(_ row: SystemSampleRow) -> [InterfaceLine] {
        guard let down = row.netInBps, let up = row.netOutBps else { return [] }
        return [InterfaceLine(name: "All interfaces", inPerSecond: down, outPerSecond: up)]
    }

    static func nowTraffic(_ rows: [AppSampleRow], names: [String: String], interval: Double) -> [TrafficLine] {
        func rate(_ bytes: Int64?) -> Double { Double(max(bytes ?? 0, 0)) / max(interval, 1) }
        return rows.compactMap { row in
            let (down, up) = (rate(row.netInBytes), rate(row.netOutBytes))
            guard down + up > 0 else { return nil }
            return TrafficLine(id: row.appKey, name: names[row.appKey] ?? row.appKey, bytesIn: down, bytesOut: up)
        }.sorted { ($1.bytesIn + $1.bytesOut, $0.name) < ($0.bytesIn + $0.bytesOut, $1.name) }
    }

    static func identityCard(_ identity: NetworkIdentity, checkEnabled: Bool, previous: IdentityCard?) -> IdentityCard {
        let vpn = identity.vpnServices.value?.first { $0.state == .connected } ?? identity.vpnServices.value?.first
        var card = IdentityCard(verdict: identity.verdict, publicIP: identity.publicIP.value?.address,
                                publicCountry: identity.publicIP.value?.country, ispIP: identity.ispIP.value?.address,
                                ispCountry: identity.ispIP.value?.country, vpnName: vpn?.label, vpnState: vpn?.state.rawValue,
                                checkEnabled: checkEnabled, reason: identity.publicIP.problem ?? identity.vpnServices.problem ?? identity.physicalInterface.problem, changeNote: nil)
        if let before = previous?.publicIP, let now = card.publicIP, before != now {
            card.changeNote = "Your public IP changed from \(before) to \(now)."
        } else {
            card.changeNote = previous?.changeNote
        }
        if !checkEnabled { card.reason = nil }
        return card
    }

    static func identityRow(_ identity: NetworkIdentity, ts: Int64) -> IdentityRow {
        let vpn = identity.vpnServices.value?.first { $0.state == .connected }
        return IdentityRow(ts: ts, publicIP: identity.publicIP.value?.address, publicCC: identity.publicIP.value?.country,
                           ispIP: identity.ispIP.value?.address, ispCC: identity.ispIP.value?.country, vpnService: vpn?.label,
                           vpnState: vpn?.state.rawValue, routeTunnel: identity.defaultRoute.value?.isTunnel,
                           verdict: identity.verdict.rawValue)
    }

    static func describe(_ connection: NetworkConnection) -> String {
        let remote = connection.remoteAddress.map { "\($0):\(connection.remotePort.map(String.init) ?? "*")" } ?? "listening"
        return "\(connection.transport) \(remote) \(connection.state)"
    }
}
