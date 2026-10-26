import Foundation

public struct ActionRow: Sendable, Equatable {
    public let ts: Int64
    public let kind: String
    public let target: String
    public let result: String
    public let detail: String?

    public init(ts: Int64, kind: String, target: String, result: String, detail: String?) {
        self.ts = ts
        self.kind = kind
        self.target = target
        self.result = result
        self.detail = detail
    }
}

extension Database {
    private static let actionTextLimit = 500

    private static func storable(_ text: String) -> String {
        // A process name or path can carry a secret: redacted before it reaches the table, then bounded.
        String((Redaction.redact([Redaction.sanitizeText(text)]).first ?? "").prefix(actionTextLimit))
    }

    /// Every action, refused or not, is recorded. Text from a process or a path is sanitized and bounded first.
    public func logAction(ts: Int64, kind: String, target: String, result: String, detail: String?) throws {
        try requireWritable()
        try execute("INSERT INTO actions(ts, kind, target, result, detail) VALUES (?1, ?2, ?3, ?4, ?5)",
                    [.int(ts), .text(Self.storable(kind)), .text(Self.storable(target)), .text(Self.storable(result)),
                     SQLiteValue(detail.map(Self.storable))])
    }

    /// Newest first.
    public func recentActions(kind: String? = nil, limit: Int) throws -> [ActionRow] {
        let rows = try query("""
            SELECT ts, kind, target, result, detail FROM actions
            WHERE (?1 IS NULL OR kind = ?1) ORDER BY ts DESC, rowid DESC LIMIT ?2
            """, [SQLiteValue(kind), .int(Int64(max(limit, 0)))]).textRows()
        return rows.compactMap { row in
            guard let ts = row[0].flatMap({ Int64($0) }), let kind = row[1], let target = row[2], let result = row[3] else { return nil }
            return ActionRow(ts: ts, kind: kind, target: target, result: result, detail: row[4])
        }
    }
}
