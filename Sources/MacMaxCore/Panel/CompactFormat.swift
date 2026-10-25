import Foundation

/// Numbers sized for a 404-point panel: compact by hand, never wider than their tile.
public enum CompactFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]

    public static func bytes(_ value: UInt64) -> String {
        var scaled = Double(value)
        var unit = 0
        while scaled >= 1_024, unit < units.count - 1 {
            scaled /= 1_024
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        // Rounding 1023.6 KB would print "1024 KB": carry into the next unit instead.
        if scaled.rounded() >= 1_024, unit < units.count - 1 {
            scaled /= 1_024
            unit += 1
        }
        let text = scaled < 9.95 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
        return "\(text) \(units[unit])"
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "-" }
        return bytes(bytesPerSecond >= 1.8e19 ? .max : UInt64(bytesPerSecond)) + "/s"
    }

    public static func count(_ value: Int) -> String {
        guard value > 0 else { return "0" }
        if value < 1_000 { return String(value) }
        // 999_999 would round to "1000K"; it reads as 1.0M instead.
        let (divisor, suffix): (Double, String) = value < 999_500 ? (1_000, "K") : (1_000_000, "M")
        let scaled = Double(value) / divisor
        return (scaled < 9.95 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)) + suffix
    }

    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        let whole = max(0, value.rounded())
        return whole > 999 ? "999%+" : "\(Int(whole))%"
    }
}
