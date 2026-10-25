import Foundation

/// How a rule compares a value with a threshold; the operators are the ones `mac-audit.sh` uses.
enum Comparison: Sendable {
    case above, atLeast, below, atMost

    func holds(_ value: Double, _ threshold: Double) -> Bool {
        switch self {
        case .above: value > threshold
        case .atLeast: value >= threshold
        case .below: value < threshold
        case .atMost: value <= threshold
        }
    }
}

/// Where a level's line comes from: an editable threshold or a number fixed by the rule.
enum Line: Sendable {
    case key(String)
    case fixed(Double)

    func resolve(_ thresholds: ResolvedThresholds) -> Double {
        switch self {
        case let .key(key): thresholds[key]
        case let .fixed(value): value
        }
    }
}

/// One severity of a threshold rule. Levels are listed worst first; the first one that holds wins.
struct Level: Sendable {
    let severity: Severity
    let comparison: Comparison
    let line: Line
}

enum NumberStyle: Sendable {
    case integer, oneDecimal, twoDecimals

    func text(_ value: Double) -> String {
        switch self {
        case .integer: String(format: "%.0f", value.isFinite ? value.rounded(.towardZero) + 0.0 : 0)
        case .oneDecimal: String(format: "%.1f", value)
        case .twoDecimals: String(format: "%.2f", value)
        }
    }
}

/// Reads of one or two snapshot fields. A failed field makes the rule unknown (the first failure's reason);
/// otherwise an unavailable field means the Mac does not have the thing, so the rule has nothing to say.
func requiring<A: Sendable & Codable & Equatable, B: Sendable & Codable & Equatable>(
    _ first: Measure<A>, _ second: Measure<B>, _ body: (A, B) -> Outcome) -> Outcome {
    if case let .failed(reason) = first { return .unknown(reason: reason) }
    if case let .failed(reason) = second { return .unknown(reason: reason) }
    guard let a = first.value, let b = second.value else { return .notApplicable }
    return body(a, b)
}

func requiring<A: Sendable & Codable & Equatable>(_ measure: Measure<A>, _ body: (A) -> Outcome) -> Outcome {
    requiring(measure, Measure<Bool>.ok(true)) { value, _ in body(value) }
}

func outcome(_ severity: Severity, _ title: String, _ evidence: [EvidenceItem]) -> Outcome {
    switch severity {
    case .crit: .crit(title: title, evidence: evidence)
    case .warn: .warn(title: title, evidence: evidence)
    case .info: .info(title: title, evidence: evidence)
    }
}

/// Entries sorted by value descending, then name, as evidence lines after the threshold.
func sortedEvidence(_ entries: [(name: String, value: Double)], format: (Double) -> String) -> [EvidenceItem] {
    entries.sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
        .map { EvidenceItem($0.name, format($0.value)) }
}

/// A rule over one number: the first level that holds gives the finding, with `value` and `threshold` evidence.
func numericRule(id: String, title: String, thresholds: [Threshold], levels: [Level], style: NumberStyle,
                 why: String, action: String?, scriptPattern: String?,
                 read: @escaping @Sendable (AuditSnapshot) -> Measure<Double>,
                 headline: @escaping @Sendable (Double, String) -> String) -> Rule {
    Rule(id: id, title: title, thresholds: thresholds, why: why, action: action, scriptPattern: scriptPattern) { snapshot, resolved in
        requiring(read(snapshot)) { value in
            for level in levels {
                let line = level.line.resolve(resolved)
                guard level.comparison.holds(value, line) else { continue }
                return outcome(level.severity, headline(value, style.text(value)),
                               [EvidenceItem("value", style.text(value)), EvidenceItem("threshold", style.text(line))])
            }
            return .pass
        }
    }
}

func integers(_ measure: Measure<Int>) -> Measure<Double> {
    switch measure {
    case let .ok(value): .ok(Double(value))
    case let .unavailable(reason): .unavailable(reason)
    case let .failed(reason): .failed(reason)
    }
}
