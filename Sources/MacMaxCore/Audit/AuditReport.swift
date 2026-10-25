import Foundation

/// Ordered worst first: the order findings are listed in.
public enum Severity: String, Sendable, Codable, Comparable {
    case crit, warn, info

    private var rank: Int {
        switch self {
        case .crit: 0
        case .warn: 1
        case .info: 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

public enum Verdict: String, Sendable, Codable, Equatable {
    case ok, warn, crit, unknown
}

/// One fact behind a finding, preformatted so the same snapshot gives byte-identical JSON.
public struct EvidenceItem: Sendable, Codable, Equatable {
    public let key: String
    public let value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

public struct Finding: Sendable, Codable, Equatable {
    public let ruleID: String
    public let severity: Severity
    public let title: String
    public let evidence: [EvidenceItem]
    public let why: String
    public let action: String?
    public let scriptPattern: String?

    public init(ruleID: String, severity: Severity, title: String, evidence: [EvidenceItem], why: String,
                action: String?, scriptPattern: String?) {
        self.ruleID = ruleID
        self.severity = severity
        self.title = title
        self.evidence = evidence
        self.why = why
        self.action = action
        self.scriptPattern = scriptPattern
    }
}

/// A rule that could not be checked and why; shown as "could not check", never as healthy.
public struct UnknownRule: Sendable, Codable, Equatable {
    public let ruleID: String
    public let title: String
    public let reason: String

    public init(ruleID: String, title: String, reason: String) {
        self.ruleID = ruleID
        self.title = title
        self.reason = reason
    }
}

public struct AuditReport: Sendable, Codable, Equatable {
    public let timestamp: Int64
    public let verdict: Verdict
    /// CRIT, then WARN, then INFO, each in rule order.
    public let findings: [Finding]
    /// In rule order.
    public let unknowns: [UnknownRule]

    public init(timestamp: Int64, verdict: Verdict, findings: [Finding], unknowns: [UnknownRule]) {
        self.timestamp = timestamp
        self.verdict = verdict
        self.findings = findings
        self.unknowns = unknowns
    }
}

/// One editable number of a rule: the script's `T_*` name, its default and the bounds Settings enforces.
public struct Threshold: Sendable, Equatable {
    public let key: String
    public let defaultValue: Double
    public let unit: String
    public let range: ClosedRange<Double>

    public init(key: String, defaultValue: Double, unit: String, range: ClosedRange<Double>) {
        self.key = key
        self.defaultValue = defaultValue
        self.unit = unit
        self.range = range
    }
}
