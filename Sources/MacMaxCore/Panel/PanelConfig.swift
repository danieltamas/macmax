import Foundation

public enum MenuBarText: String, Codable, Sendable, CaseIterable { case none, cpu, memory, network, country }
public enum NotifyLevel: String, Codable, Sendable, CaseIterable { case critOnly, warnAndCrit, never }

/// Every setting the app has; `config.json` holds nothing else. Bounds are applied by `ConfigStore`.
public struct PanelConfig: Codable, Equatable, Sendable {
    public var samplingSeconds: Int
    public var menuBarText: MenuBarText
    public var auditEveryHours: Int
    public var auditOnCriticalPressure: Bool
    public var notifyOn: NotifyLevel
    public var ipCheckEnabled: Bool
    public var ipEndpoint: String?
    public var thresholds: [String: Double]
    public var disabledRules: [String]
    public var lookName: String?
    /// Folders the user keeps out of cleanup, on top of the built-in protected list.
    public var protectedPaths: [String] = []
    /// Whether `macmax mcp` may answer tool calls. Off until the user turns it on in Settings > Agent access.
    public var agentAccess: Bool = false

    public static let `default` = PanelConfig(
        samplingSeconds: 10, menuBarText: .none, auditEveryHours: 4, auditOnCriticalPressure: true,
        notifyOn: .critOnly, ipCheckEnabled: false, ipEndpoint: nil, thresholds: [:], disabledRules: [], lookName: nil)

    public init(samplingSeconds: Int, menuBarText: MenuBarText, auditEveryHours: Int, auditOnCriticalPressure: Bool,
                notifyOn: NotifyLevel, ipCheckEnabled: Bool, ipEndpoint: String?, thresholds: [String: Double],
                disabledRules: [String], lookName: String?) {
        self.samplingSeconds = samplingSeconds
        self.menuBarText = menuBarText
        self.auditEveryHours = auditEveryHours
        self.auditOnCriticalPressure = auditOnCriticalPressure
        self.notifyOn = notifyOn
        self.ipCheckEnabled = ipCheckEnabled
        self.ipEndpoint = ipEndpoint
        self.thresholds = thresholds
        self.disabledRules = disabledRules
        self.lookName = lookName
    }

    /// A missing key takes its default and an unknown key is ignored, so an older or newer file still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let base = PanelConfig.default
        samplingSeconds = try values.decodeIfPresent(Int.self, forKey: .samplingSeconds) ?? base.samplingSeconds
        menuBarText = try values.decodeIfPresent(MenuBarText.self, forKey: .menuBarText) ?? base.menuBarText
        auditEveryHours = try values.decodeIfPresent(Int.self, forKey: .auditEveryHours) ?? base.auditEveryHours
        auditOnCriticalPressure = try values.decodeIfPresent(Bool.self, forKey: .auditOnCriticalPressure)
            ?? base.auditOnCriticalPressure
        notifyOn = try values.decodeIfPresent(NotifyLevel.self, forKey: .notifyOn) ?? base.notifyOn
        ipCheckEnabled = try values.decodeIfPresent(Bool.self, forKey: .ipCheckEnabled) ?? base.ipCheckEnabled
        ipEndpoint = try values.decodeIfPresent(String.self, forKey: .ipEndpoint)
        thresholds = try values.decodeIfPresent([String: Double].self, forKey: .thresholds) ?? [:]
        disabledRules = try values.decodeIfPresent([String].self, forKey: .disabledRules) ?? []
        lookName = try values.decodeIfPresent(String.self, forKey: .lookName)
        protectedPaths = try values.decodeIfPresent([String].self, forKey: .protectedPaths) ?? []
        agentAccess = try values.decodeIfPresent(Bool.self, forKey: .agentAccess) ?? false
    }

    private enum Key: String, CodingKey {
        case samplingSeconds, menuBarText, auditEveryHours, auditOnCriticalPressure, notifyOn, ipCheckEnabled
        case ipEndpoint, thresholds, disabledRules, lookName, protectedPaths, agentAccess
    }

    /// Replaces every out-of-range value by something the app can run with.
    func bounded() -> PanelConfig {
        var config = self
        if !SamplerInterval.allCases.contains(where: { $0.rawValue == samplingSeconds }) { config.samplingSeconds = 10 }
        if ![0, 1, 4, 12, 24].contains(auditEveryHours) { config.auditEveryHours = 4 }
        let declared = Dictionary(RuleSet.all.flatMap(\.thresholds).map { ($0.key, $0.range) }, uniquingKeysWith: { first, _ in first })
        config.thresholds = thresholds.reduce(into: [:]) { result, entry in
            guard entry.value.isFinite, let range = declared[entry.key] else { return }
            result[entry.key] = min(max(entry.value, range.lowerBound), range.upperBound)
        }
        config.protectedPaths = Set(protectedPaths.filter { $0.hasPrefix("/") && !$0.contains("\0") }).sorted()
        let known = Set(RuleSet.all.map(\.id))
        config.disabledRules = Set(disabledRules).intersection(known).sorted()
        if let endpoint = ipEndpoint {
            let url = URL(string: endpoint)
            let valid = url?.scheme?.lowercased() == "https" && url?.host?.isEmpty == false
                && url?.user == nil && url?.password == nil
            config.ipEndpoint = valid ? endpoint : nil
        }
        return config
    }
}
