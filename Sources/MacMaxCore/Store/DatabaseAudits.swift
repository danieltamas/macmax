import Foundation

/// An audit as stored: its snapshot and findings. The report is rebuilt from them (why, action and pattern come
/// from the rule with the same id; unknown rules are not stored).
public struct StoredAudit: Sendable {
    public let id: Int64
    public let timestamp: Int64
    public let verdict: Verdict
    public let durationMilliseconds: Int
    public let snapshot: AuditSnapshot
    public let findings: [Finding]

    public init(id: Int64, timestamp: Int64, verdict: Verdict, durationMilliseconds: Int, snapshot: AuditSnapshot,
                findings: [Finding]) {
        self.id = id
        self.timestamp = timestamp
        self.verdict = verdict
        self.durationMilliseconds = durationMilliseconds
        self.snapshot = snapshot
        self.findings = findings
    }

    public var report: AuditReport {
        AuditReport(timestamp: timestamp, verdict: verdict, findings: findings, unknowns: [])
    }
}

extension Database {
    /// One transaction: the audit row (snapshot as JSON) and one row per finding. Returns the audit id.
    public func writeAudit(_ report: AuditReport, snapshot: AuditSnapshot, durationMilliseconds: Int) throws -> Int64 {
        try requireWritable()
        let snapshotJSON = String(decoding: try Self.encoder.encode(snapshot), as: UTF8.self)
        let evidence = try report.findings.map { String(decoding: try Self.encoder.encode($0.evidence), as: UTF8.self) }
        return try transaction {
            try execute("INSERT INTO audits(ts, verdict, duration_ms, snapshot_json) VALUES(?,?,?,?)",
                        [.int(report.timestamp), .text(report.verdict.rawValue), .int(Int64(durationMilliseconds)),
                         .text(snapshotJSON)])
            guard let id = try query("SELECT last_insert_rowid()").firstInt(), id > 0 else {
                throw StoreError.invalid("the audit row id was not returned")
            }
            for (finding, evidenceJSON) in zip(report.findings, evidence) {
                try execute("INSERT INTO findings(audit_id, rule_id, severity, title, evidence_json) VALUES(?,?,?,?,?)",
                            [.int(id), .text(finding.ruleID), .text(finding.severity.rawValue), .text(finding.title),
                             .text(evidenceJSON)])
            }
            return id
        }
    }

    /// The newest audit by timestamp, nil when there is none. Unreadable stored JSON throws: a damaged history
    /// must not read as "no previous audit".
    public func latestAudit() throws -> StoredAudit? {
        guard let row = try query("""
            SELECT id, ts, verdict, duration_ms, snapshot_json FROM audits ORDER BY ts DESC, id DESC LIMIT 1
            """).textRows().first else { return nil }
        // A row that exists but does not parse is a damaged history, not "no previous audit".
        guard let idText = row[0], let id = Int64(idText), let tsText = row[1], let timestamp = Int64(tsText),
              let verdict = row[2].flatMap(Verdict.init(rawValue:)), let durationText = row[3],
              let duration = Int(durationText), let json = row[4]
        else { throw StoreError.invalid("the newest stored audit is damaged") }
        let snapshot = try Self.decoder.decode(AuditSnapshot.self, from: Data(json.utf8))
        let findings = try query("""
            SELECT rule_id, severity, title, evidence_json FROM findings WHERE audit_id = ? ORDER BY rowid
            """, [.int(id)]).textRows().map { columns -> Finding in
            guard let ruleID = columns[0], let severity = columns[1].flatMap(Severity.init(rawValue:)),
                  let title = columns[2], let evidenceJSON = columns[3] else {
                throw StoreError.invalid("a stored finding is incomplete")
            }
            let rule = RuleSet.all.first { $0.id == ruleID }
            return Finding(ruleID: ruleID, severity: severity, title: title,
                           evidence: try Self.decoder.decode([EvidenceItem].self, from: Data(evidenceJSON.utf8)),
                           why: rule?.why ?? "", action: rule?.action, scriptPattern: rule?.scriptPattern)
        }
        return StoredAudit(id: id, timestamp: timestamp, verdict: verdict, durationMilliseconds: duration,
                           snapshot: snapshot, findings: findings)
    }

    /// Findings of the audits at or after `since`, newest audit first. Why and action come from the rule with the same id.
    public func findings(since: Int64, limit: Int = 200) throws -> [(timestamp: Int64, finding: Finding)] {
        try query("""
            SELECT a.ts, f.rule_id, f.severity, f.title, f.evidence_json FROM findings f JOIN audits a ON a.id = f.audit_id
            WHERE a.ts >= ? ORDER BY a.ts DESC, f.rowid LIMIT ?
            """, [.int(since), .int(Int64(max(limit, 0)))]).textRows().map { columns in
            guard let ts = columns[0].flatMap({ Int64($0) }), let ruleID = columns[1],
                  let severity = columns[2].flatMap(Severity.init(rawValue:)), let title = columns[3], let evidenceJSON = columns[4]
            else { throw StoreError.invalid("a stored finding is incomplete") }
            let rule = RuleSet.all.first { $0.id == ruleID }
            return (ts, Finding(ruleID: ruleID, severity: severity, title: title,
                                evidence: try Self.decoder.decode([EvidenceItem].self, from: Data(evidenceJSON.utf8)),
                                why: rule?.why ?? "", action: rule?.action, scriptPattern: rule?.scriptPattern))
        }
    }

    /// Footprint per app key in the newest tick at or before `timestamp`, if that tick is within
    /// `toleranceSeconds` of it; nil when there is no such tick. Apps without a footprint are left out.
    public func appFootprints(near timestamp: Int64, toleranceSeconds: Int64) throws -> [String: UInt64]? {
        guard let tick = try query("SELECT MAX(ts) FROM samples WHERE ts <= ?", [.int(timestamp)]).firstInt(),
              timestamp - tick <= toleranceSeconds else { return nil }
        var footprints: [String: UInt64] = [:]
        for row in try query("SELECT app_key, footprint FROM app_samples WHERE ts = ? AND footprint IS NOT NULL",
                             [.int(tick)]).textRows() {
            guard let key = row[0], let value = row[1].flatMap({ UInt64($0) }) else {
                throw StoreError.invalid("a stored app footprint is damaged")
            }
            footprints[key] = value
        }
        return footprints
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}
