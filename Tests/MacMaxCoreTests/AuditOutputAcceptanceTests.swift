import Foundation
import Testing
@testable import MacMaxCore

@Suite("Audit output acceptance")
struct AuditOutputAcceptanceTests {
    @Test("Audit exit codes map every verdict")
    func exitCodes() {
        #expect(AuditExit.code(for: .ok) == 0)
        #expect(AuditExit.code(for: .warn) == 1)
        #expect(AuditExit.code(for: .crit) == 2)
        #expect(AuditExit.code(for: .unknown) == 3)
    }

    @Test("The audit envelope is deterministic, sorted snake-case JSON with the complete rule catalog")
    func envelopeContract() throws {
        var snapshot = healthyAuditSnapshot()
        snapshot.swapUsedGB = .ok(7)
        let report = AuditEngine.evaluate(snapshot)
        let generatedAt = try #require(ISO8601DateFormatter().date(from: "2026-10-25T09:14:02Z"))
        let first = try AuditEnvelope.encode(report, generatedAt: generatedAt)
        for _ in 0..<100 { #expect(try AuditEnvelope.encode(report, generatedAt: generatedAt) == first) }
        #expect(String(decoding: first, as: UTF8.self).contains("\n") == false)

        let object = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(object["source"] as? String == "macmax")
        #expect(object["generated_at"] as? String == "2026-10-25T09:14:02Z")
        #expect((object["data_note"] as? String)?.localizedCaseInsensitiveContains("untrusted") == true)
        #expect(object["timestamp"] as? Int64 == report.timestamp)
        #expect(object["verdict"] as? String == report.verdict.rawValue)

        let reportObject = try #require(JSONSerialization.jsonObject(with: AuditJSON.encode(report)) as? [String: Any])
        #expect(try canonicalJSON(object["findings"] as Any) == canonicalJSON(reportObject["findings"] as Any))
        #expect(try canonicalJSON(object["unknowns"] as Any) == canonicalJSON(reportObject["unknowns"] as Any))
        let rules = try #require(object["rules"] as? [[String: Any]])
        #expect(rules.count == RuleSet.all.count)
        #expect(zip(rules, RuleSet.all).allSatisfy { encoded, rule in
            encoded["rule_id"] as? String == rule.id && encoded["title"] as? String == rule.title
                && encoded["script_pattern"] as? String == rule.scriptPattern
                && (rule.scriptPattern != nil || encoded.keys.contains("script_pattern") == false)
        })
    }

    @Test("vpn_leak distinguishes leak, unknown, off and safe verdicts")
    func vpnLeakSemantics() {
        var snapshot = healthyAuditSnapshot()
        snapshot.identity = .ok(IdentityFacts(verdict: LeakVerdict.leak.rawValue, vpnConnected: true,
                                              publicIP: "192.0.2.1", publicCountry: "RO"))
        expectAuditFinding("vpn_leak", .crit, snapshot)

        snapshot.identity = .ok(IdentityFacts(verdict: LeakVerdict.unknown.rawValue, vpnConnected: true,
                                              publicIP: nil, publicCountry: nil))
        let unknown = AuditEngine.evaluate(snapshot)
        #expect(unknown.findings.contains { $0.ruleID == "vpn_leak" } == false)
        #expect(unknown.unknowns.first { $0.ruleID == "vpn_leak" }?.reason.isEmpty == false)

        for verdict in [LeakVerdict.off, .noVPN, .splitTunnel, .tunnelOK] {
            snapshot.identity = .ok(IdentityFacts(verdict: verdict.rawValue, vpnConnected: false,
                                                  publicIP: "198.51.100.2", publicCountry: "RO"))
            let report = AuditEngine.evaluate(snapshot)
            #expect(report.findings.contains { $0.ruleID == "vpn_leak" } == false)
            #expect(report.unknowns.contains { $0.ruleID == "vpn_leak" } == false)
        }
    }
}

private func canonicalJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
