import Foundation

public enum AuditEngine {
    /// Evaluates every enabled rule against one snapshot. Pure: no clock, no I/O, no ambient state.
    /// `thresholds` holds the user's overrides by `T_*` key; they are clamped to each rule's bounds.
    /// `disabled` is a set of rule ids the user turned off.
    public static func evaluate(_ snapshot: AuditSnapshot, thresholds: [String: Double] = [:],
                                disabled: Set<String> = []) -> AuditReport {
        let rules = RuleSet.all.filter { !disabled.contains($0.id) }
        let resolved = ResolvedThresholds(rules: rules, overrides: thresholds)
        var findings: [Finding] = []
        var unknowns: [UnknownRule] = []
        var checked = 0
        for rule in rules {
            let make = { (severity: Severity, title: String, evidence: [EvidenceItem]) in
                Finding(ruleID: rule.id, severity: severity, title: title, evidence: evidence, why: rule.why,
                        action: rule.action, scriptPattern: rule.scriptPattern)
            }
            switch rule.evaluate(snapshot, resolved) {
            case .pass: checked += 1
            case .notApplicable: break
            case let .info(title, evidence):
                checked += 1
                findings.append(make(.info, title, evidence))
            case let .warn(title, evidence):
                checked += 1
                findings.append(make(.warn, title, evidence))
            case let .crit(title, evidence):
                checked += 1
                findings.append(make(.crit, title, evidence))
            case let .unknown(reason): unknowns.append(UnknownRule(ruleID: rule.id, title: rule.title, reason: reason))
            }
        }
        // Stable: within a severity the rule order is kept.
        let ordered = [Severity.crit, .warn, .info].flatMap { severity in findings.filter { $0.severity == severity } }
        return AuditReport(timestamp: snapshot.timestamp, verdict: verdict(ordered, checked: checked, unknownCount: unknowns.count),
                           findings: ordered, unknowns: unknowns)
    }

    /// Unknown only when some rule could not be checked and none could; unknown rules are otherwise listed beside the verdict.
    private static func verdict(_ findings: [Finding], checked: Int, unknownCount: Int) -> Verdict {
        if checked == 0, unknownCount > 0 { return .unknown }
        if findings.contains(where: { $0.severity == .crit }) { return .crit }
        if findings.contains(where: { $0.severity == .warn }) { return .warn }
        return .ok
    }
}

public enum AuditJSON {
    /// Sorted keys and snake_case: one report always gives the same bytes.
    public static func encode(_ report: AuditReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(report)
    }
}

public enum NotificationDiff {
    /// The findings worth a notification: with no previous audit only CRIT; otherwise those that are new
    /// or got worse (a higher severity than the same rule had). An unchanged finding never repeats.
    public static func changes(previous: AuditReport?, current: AuditReport) -> [Finding] {
        guard let previous else { return current.findings.filter { $0.severity == .crit } }
        let before = Dictionary(previous.findings.map { ($0.ruleID, $0.severity) }, uniquingKeysWith: { first, _ in first })
        return current.findings.filter { finding in
            guard let was = before[finding.ruleID] else { return true }
            return finding.severity < was
        }
    }
}
