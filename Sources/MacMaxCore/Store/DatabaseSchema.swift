import Foundation

/// The schema of docs/ARCHITECTURE.md (Store). Tables with many rows per tick are WITHOUT ROWID with the
/// natural key as primary key: no second index, so 90 days stay small. Every statement is idempotent.
enum DatabaseSchema {
    private static let sampleColumns = """
        cpu_user REAL, cpu_system REAL, mem_used INTEGER, mem_compressed INTEGER, swap_used INTEGER,
        swapins_ps REAL, pressure_level INTEGER, disk_free INTEGER, disk_read_bps REAL, disk_write_bps REAL,
        net_in_bps REAL, net_out_bps REAL, thermal INTEGER
        """
    private static let appColumns = """
        cpu REAL, footprint INTEGER, disk_read_bps REAL, disk_write_bps REAL, net_in_bytes INTEGER, net_out_bytes INTEGER
        """

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS apps(app_key TEXT PRIMARY KEY, name TEXT, bundle_id TEXT, path TEXT, first_seen INTEGER)",
        "CREATE TABLE IF NOT EXISTS samples(ts INTEGER PRIMARY KEY, \(sampleColumns))",
        "CREATE TABLE IF NOT EXISTS app_samples(ts INTEGER NOT NULL, app_key TEXT NOT NULL, \(appColumns), procs INTEGER, PRIMARY KEY(ts, app_key)) WITHOUT ROWID",
        """
        CREATE TABLE IF NOT EXISTS proc_samples(ts INTEGER NOT NULL, pid INTEGER NOT NULL, start_us INTEGER NOT NULL, app_key TEXT,
        name TEXT, cpu REAL, footprint INTEGER, PRIMARY KEY(ts, pid, start_us)) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS samples_1m(ts INTEGER PRIMARY KEY, n INTEGER, \(sampleColumns),
        cpu_max REAL, mem_used_max INTEGER, net_in_bps_max REAL, net_out_bps_max REAL)
        """,
        """
        CREATE TABLE IF NOT EXISTS samples_1h(ts INTEGER PRIMARY KEY, n INTEGER, \(sampleColumns),
        cpu_max REAL, mem_used_max INTEGER, net_in_bps_max REAL, net_out_bps_max REAL)
        """,
        """
        CREATE TABLE IF NOT EXISTS app_samples_1m(ts INTEGER NOT NULL, app_key TEXT NOT NULL, n INTEGER, \(appColumns), procs INTEGER,
        cpu_max REAL, footprint_max INTEGER, PRIMARY KEY(ts, app_key)) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS app_samples_1h(ts INTEGER NOT NULL, app_key TEXT NOT NULL, n INTEGER, \(appColumns), procs INTEGER,
        cpu_max REAL, footprint_max INTEGER, PRIMARY KEY(ts, app_key)) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS identity(ts INTEGER PRIMARY KEY, public_ip TEXT, public_cc TEXT, isp_ip TEXT, isp_cc TEXT,
        vpn_service TEXT, vpn_state TEXT, route_tunnel INTEGER, verdict TEXT)
        """,
        "CREATE TABLE IF NOT EXISTS audits(id INTEGER PRIMARY KEY, ts INTEGER, verdict TEXT, duration_ms INTEGER, snapshot_json TEXT)",
        "CREATE INDEX IF NOT EXISTS audits_ts ON audits(ts)",
        "CREATE TABLE IF NOT EXISTS findings(audit_id INTEGER, rule_id TEXT, severity TEXT, title TEXT, evidence_json TEXT)",
        "CREATE INDEX IF NOT EXISTS findings_audit ON findings(audit_id)",
        "CREATE TABLE IF NOT EXISTS actions(ts INTEGER, kind TEXT, target TEXT, result TEXT, detail TEXT)",
        "CREATE INDEX IF NOT EXISTS actions_ts ON actions(ts)",
    ]

    static let sampleAverages = [
        "cpu_user", "cpu_system", "mem_used", "mem_compressed", "swap_used", "swapins_ps", "pressure_level", "disk_free",
        "disk_read_bps", "disk_write_bps", "net_in_bps", "net_out_bps", "thermal",
    ]
    static let appAverages = ["cpu", "footprint", "disk_read_bps", "disk_write_bps"]
}
