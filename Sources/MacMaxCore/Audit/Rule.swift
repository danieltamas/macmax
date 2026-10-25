import Foundation

/// What one rule says about one snapshot.
public enum Outcome: Sendable, Equatable {
    /// Checked and healthy.
    case pass
    /// Nothing to check on this Mac (no Docker, a setting off, an Intel chip).
    case notApplicable
    case info(title: String, evidence: [EvidenceItem])
    case warn(title: String, evidence: [EvidenceItem])
    case crit(title: String, evidence: [EvidenceItem])
    case unknown(reason: String)
}

/// The thresholds a rule evaluates with: defaults, replaced by the user's values within their bounds.
public struct ResolvedThresholds: Sendable, Equatable {
    private let values: [String: Double]

    public init(rules: [Rule], overrides: [String: Double] = [:]) {
        var values: [String: Double] = [:]
        for threshold in rules.flatMap(\.thresholds) {
            let chosen = overrides[threshold.key].flatMap { $0.isFinite ? $0 : nil } ?? threshold.defaultValue
            values[threshold.key] = min(max(chosen, threshold.range.lowerBound), threshold.range.upperBound)
        }
        self.values = values
    }

    /// The value of a key a rule declared; a key nobody declared is a programming error.
    public subscript(key: String) -> Double { values[key] ?? .nan }
}

/// A rule is data plus a pure function over one snapshot. `ruleOrder` is its position in the set.
public struct Rule: Sendable {
    public let id: String
    public let title: String
    public let thresholds: [Threshold]
    public let why: String
    public let action: String?
    /// Regex, anchored, that matches the `mac-audit.sh` verdict message of this rule (after its `[SEV] `); parity only matches.
    public let scriptPattern: String?
    public let evaluate: @Sendable (AuditSnapshot, ResolvedThresholds) -> Outcome

    public init(id: String, title: String, thresholds: [Threshold], why: String, action: String?,
                scriptPattern: String?, evaluate: @escaping @Sendable (AuditSnapshot, ResolvedThresholds) -> Outcome) {
        self.id = id
        self.title = title
        self.thresholds = thresholds
        self.why = why
        self.action = action
        self.scriptPattern = scriptPattern
        self.evaluate = evaluate
    }
}
