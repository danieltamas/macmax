import Foundation

/// Battery wear and fan and temperature readings, read on demand (the panel asks when it opens), not on the system tick:
/// they are slow-moving and the SMC read walks every key.
public enum PowerHealthReader {
    public static func batteryHealth(at: Date = .now) -> Reading<BatteryHealth> {
        guard let batteries = IOKitReadings.entries(matching: "AppleSmartBattery") else {
            return .failed(reason: "the IO registry could not be read for the battery")
        }
        guard let battery = batteries.first else { return .unavailable(reason: "this Mac has no battery") }
        return BatteryHealthParser.parse(battery.properties, at: at)
    }

    /// Charge, power source and charging state: what the battery is doing now, next to how worn it is.
    public static func batteryStatus(at: Date = .now) -> Reading<BatteryStatus> { IOKitReadings.battery(at: at) }

    public static func thermalSensors(at: Date = .now) -> Reading<ThermalSensors> {
        switch SMCReader.readings(at: at) {
        case let .ok(values, _, _): return ThermalSensorSummary.summarize(values, at: at)
        case let .unavailable(reason): return .unavailable(reason: reason)
        case let .failed(reason): return .failed(reason: reason)
        }
    }
}
