import Foundation

public enum BatteryCondition: Sendable, Equatable { case normal, serviceRecommended }

/// How worn the battery is, from the registry's own counters.
public struct BatteryHealth: Sendable, Equatable {
    public let cycleCount: Int
    public let designCycleCount: Int?
    public let maximumCapacityPercent: Int
    public let temperatureCelsius: Double?
    public let condition: BatteryCondition

    public init(cycleCount: Int, designCycleCount: Int?, maximumCapacityPercent: Int, temperatureCelsius: Double?, condition: BatteryCondition) {
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.maximumCapacityPercent = maximumCapacityPercent
        self.temperatureCelsius = temperatureCelsius
        self.condition = condition
    }
}

public enum BatteryHealthParser {
    /// `properties` is the AppleSmartBattery registry dictionary. A missing or odd required value is "failed", never a guess.
    public static func parse(_ properties: [String: Any], at: Date) -> Reading<BatteryHealth> {
        if let installed = number(properties["BatteryInstalled"]), installed == 0 { return .unavailable(reason: "this Mac has no battery installed") }
        guard let cycles = integer(properties["CycleCount"]), cycles >= 0,
              let design = integer(properties["DesignCapacity"]), design > 0 else {
            return .failed(reason: "the battery did not report its cycle count and design capacity")
        }
        let maximum = integer(properties["MaxCapacity"]).flatMap { $0 > 100 ? $0 : nil }
        guard let capacity = [integer(properties["NominalChargeCapacity"]), integer(properties["AppleRawMaxCapacity"]), maximum]
            .compactMap({ $0 }).first(where: { $0 > 0 }) else {
            return .failed(reason: "the battery did not report its current maximum capacity")
        }
        let percent = min(100, max(1, (capacity * 100 + design / 2) / design))
        let temperature = number(properties["Temperature"]).map { $0 / 100 }.flatMap { (-20 ... 100).contains($0) ? $0 : nil }
        let failure = number(properties["PermanentFailureStatus"]).map { $0 != 0 } ?? false
        return .ok(BatteryHealth(cycleCount: cycles, designCycleCount: integer(properties["DesignCycleCount9C"]).flatMap { $0 > 0 ? $0 : nil },
                                 maximumCapacityPercent: percent, temperatureCelsius: temperature,
                                 condition: failure ? .serviceRecommended : .normal), source: "AppleSmartBattery", at: at)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// A whole number that is not a Bool (a flag in a count's place is not a count).
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e12 else { return nil }
        return Int(double)
    }
}

public enum SMCDecoder {
    /// One SMC value as a number. nil for an unknown type, a byte count that does not match, or a non-finite result.
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch (type, bytes.count) {
        case ("flt ", 4):
            let value = Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
            return value.isFinite ? value : nil
        case ("ui8 ", 1): return Double(bytes[0])
        case ("ui16", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4): return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case ("sp78", 2): return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
    }
}

public struct Fan: Sendable, Equatable {
    public let index: Int
    public let rpm: Int
    public let minimumRPM: Int?
    public let maximumRPM: Int?

    public init(index: Int, rpm: Int, minimumRPM: Int?, maximumRPM: Int?) {
        self.index = index
        self.rpm = rpm
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
    }
}

public struct ThermalSensors: Sendable, Equatable {
    public let fans: [Fan]
    public let hottestCelsius: Double?
    public let hottestSensor: String?
    public let sensorCount: Int

    public init(fans: [Fan], hottestCelsius: Double?, hottestSensor: String?, sensorCount: Int) {
        self.fans = fans
        self.hottestCelsius = hottestCelsius
        self.hottestSensor = hottestSensor
        self.sensorCount = sensorCount
    }
}

public enum ThermalSensorSummary {
    private static let maximumFans = 8

    /// `values` maps SMC key to its decoded value. An unknown fan count is "failed": it must not read as "no fans".
    public static func summarize(_ values: [String: Double], at: Date) -> Reading<ThermalSensors> {
        guard let count = values["FNum"] else { return .failed(reason: "the fan count was not reported") }
        guard count == count.rounded(), (0 ... Double(maximumFans)).contains(count) else { return .failed(reason: "the fan count is not plausible") }
        var fans: [Fan] = []
        for index in 0 ..< Int(count) {
            guard let current = values["F\(index)Ac"], current >= 0, current < 1e6 else { return .failed(reason: "fan \(index + 1) did not report its speed") }
            fans.append(Fan(index: index, rpm: Int(current.rounded()), minimumRPM: speed(values["F\(index)Mn"]), maximumRPM: speed(values["F\(index)Mx"])))
        }
        let plausible = values.filter { isTemperatureKey($0.key) && $0.value > 1 && $0.value <= 125 }
        let hottest = plausible.min { ($0.value, $1.key) > ($1.value, $0.key) }
        return .ok(ThermalSensors(fans: fans, hottestCelsius: hottest?.value, hottestSensor: hottest?.key, sensorCount: plausible.count),
                   source: "AppleSMC", at: at)
    }

    private static func speed(_ value: Double?) -> Int? {
        guard let value, value > 0, value < 1e6 else { return nil }
        return Int(value.rounded())
    }

    private static func isTemperatureKey(_ key: String) -> Bool {
        let characters = Array(key.unicodeScalars)
        return characters.count == 4 && characters[0] == "T" && characters[1].properties.isAlphabetic
            && characters[1].isASCII && characters[2...].allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0" ... "9").contains($0)) }
    }
}

public enum PowerWording {
    public static func batterySummary(_ health: BatteryHealth) -> String {
        let cycles = health.designCycleCount.map { "\(health.cycleCount) of \($0)" } ?? "\(health.cycleCount)"
        let rated = health.designCycleCount == nil ? "charge cycles" : "rated charge cycles"
        let base = "The battery holds \(health.maximumCapacityPercent)% of its original capacity after \(cycles) \(rated)."
        return health.condition == .serviceRecommended ? base + " The battery reports a fault: have it checked at service." : base
    }

    public static func fanSummary(_ sensors: ThermalSensors) -> String {
        if sensors.fans.isEmpty { return "This Mac has no fans; it cools itself passively." }
        return "Fans: " + sensors.fans.map { "\($0.rpm) rpm" }.joined(separator: ", ") + "."
    }
}
