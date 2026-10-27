import Foundation

public enum SensorGroup: String, Sendable, Equatable, CaseIterable {
    case cpu, gpu, memory, storage, battery, wireless, airflow, power

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .battery: "Battery"
        case .wireless: "Wireless"
        case .airflow: "Airflow"
        case .power: "Power"
        }
    }
}

public enum SensorUnit: Sendable, Equatable { case celsius, volts, amps, watts }

public struct NamedSensor: Sendable, Equatable {
    public let key: String
    public let name: String
    public let group: SensorGroup
    public let unit: SensorUnit
    public let value: Double

    public init(key: String, name: String, group: SensorGroup, unit: SensorUnit, value: Double) {
        self.key = key
        self.name = name
        self.group = group
        self.unit = unit
        self.value = value
    }
}

public struct SensorGroupSummary: Sendable, Equatable {
    public let group: SensorGroup
    public let sensors: [NamedSensor]
    public let hottestCelsius: Double?
    public let averageCelsius: Double?
}

/// Which SMC keys are sensors worth naming, and what they are called. The keys are undocumented and differ per chip
/// generation, so only an allowlist is shown: guessing from a key's prefix once surfaced an 8 C "airflow" and a
/// 16-million-volt rail. The generation is not read from the chip name; it is the list whose keys read on this Mac.
public enum SensorCatalog {
    struct Entry { let key: String, name: String, group: SensorGroup, unit: SensorUnit }

    private static func cores(_ keys: [String], _ role: String) -> [Entry] {
        keys.enumerated().map { Entry(key: $1, name: "CPU \(role) core \($0 + 1)", group: .cpu, unit: .celsius) }
    }

    private static func numbered(_ keys: [String], _ name: String, _ group: SensorGroup) -> [Entry] {
        keys.enumerated().map { Entry(key: $1, name: "\(name) \($0 + 1)", group: group, unit: .celsius) }
    }

    /// In order of preference on a tie. The key sets come from what each generation publishes; a Mac answers the list
    /// of its own generation and leaves most of the others unreadable.
    static let generations: [[Entry]] = [
        cores(["Tp09", "Tp0T"], "efficiency") + cores(["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"], "performance")
            + numbered(["Tg05", "Tg0D", "Tg0L", "Tg0T"], "GPU", .gpu) + numbered(["Tm02", "Tm06", "Tm08", "Tm09"], "Memory", .memory),
        cores(["Tp1h", "Tp1t", "Tp1p", "Tp1l"], "efficiency") + cores(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"], "performance")
            + numbered(["Tg0f", "Tg0j"], "GPU", .gpu),
        cores(["Te05", "Te0L", "Te0P", "Te0S"], "efficiency")
            + cores(["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"], "performance")
            + numbered(["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"], "GPU", .gpu),
        cores(["Te05", "Te0S", "Te09", "Te0H"], "efficiency") + cores(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"], "performance")
            + numbered(["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e"], "GPU", .gpu)
            + numbered(["Tm0p", "Tm1p", "Tm2p"], "Memory", .memory),
    ]

    static let generic: [Entry] = [
        Entry(key: "TW0P", name: "Wireless chip", group: .wireless, unit: .celsius),
        Entry(key: "TH0x", name: "Storage", group: .storage, unit: .celsius),
        Entry(key: "TB1T", name: "Battery 1", group: .battery, unit: .celsius),
        Entry(key: "TB2T", name: "Battery 2", group: .battery, unit: .celsius),
        Entry(key: "TaLP", name: "Airflow left", group: .airflow, unit: .celsius),
        Entry(key: "TaRF", name: "Airflow right", group: .airflow, unit: .celsius),
    ]

    static let electrical: [Entry] = [
        Entry(key: "VD0R", name: "DC in", group: .power, unit: .volts),
        Entry(key: "ID0R", name: "DC in", group: .power, unit: .amps),
        Entry(key: "PDTR", name: "DC in", group: .power, unit: .watts),
        Entry(key: "VP0R", name: "12 V rail", group: .power, unit: .volts),
        Entry(key: "IU1R", name: "Thunderbolt left", group: .power, unit: .amps),
        Entry(key: "IU2R", name: "Thunderbolt right", group: .power, unit: .amps),
        Entry(key: "IDBR", name: "Display brightness", group: .power, unit: .amps),
        Entry(key: "PPBR", name: "Battery", group: .power, unit: .watts),
        Entry(key: "PSTR", name: "System total", group: .power, unit: .watts),
    ]

    public static let allKeys: Set<String> = Set((generations.flatMap { $0 } + generic + electrical).map(\.key))

    /// The SMC keys the reader must fetch beyond the temperature and fan keys it already walks.
    public static let electricalKeys: Set<String> = Set(electrical.map(\.key))

    public static func name(_ values: [String: Double]) -> [NamedSensor] {
        func plausible(_ entry: Entry) -> NamedSensor? {
            guard let value = values[entry.key], value.isFinite, isPlausible(value, entry.unit) else { return nil }
            return NamedSensor(key: entry.key, name: entry.name, group: entry.group, unit: entry.unit, value: value)
        }
        return bestGeneration(present: { values[$0.key] != nil }).compactMap(plausible)
            + generic.compactMap(plausible) + electrical.compactMap(plausible)
    }

    /// The list with the most keys the SMC exposes, among those with at least half of theirs; a strict comparison
    /// keeps the earlier list on a tie. Exposure, not the value, decides: the reader keeps an exposed key that failed
    /// to decode as NaN, and the key set of a Mac never changes, so one odd tick cannot flip the list and rename a
    /// key the lists share, such as Tp09.
    private static func bestGeneration(present: (Entry) -> Bool) -> [Entry] {
        var best: [Entry] = []
        for list in generations {
            let count = list.filter(present).count
            guard count >= (list.count + 1) / 2, count > best.filter(present).count else { continue }
            best = list
        }
        return best
    }

    public static func groups(_ sensors: [NamedSensor]) -> [SensorGroupSummary] {
        SensorGroup.allCases.compactMap { group in
            let members = sensors.filter { $0.group == group }
            guard !members.isEmpty else { return nil }
            let temperatures = members.filter { $0.unit == .celsius }.map(\.value)
            return SensorGroupSummary(group: group, sensors: members, hottestCelsius: temperatures.max(),
                                      averageCelsius: temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count))
        }
    }

    static func isPlausible(_ value: Double, _ unit: SensorUnit) -> Bool {
        switch unit {
        case .celsius: value > 1 && value <= 125
        case .volts: value > 0 && value < 100
        case .amps: value >= 0 && value < 100
        case .watts: value >= 0 && value < 1000
        }
    }
}
