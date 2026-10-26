import Foundation
import Testing
@testable import MacMaxCore

@Suite("U15 battery health")
struct BatteryHealthAcceptanceTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("An explicitly absent battery is unavailable")
    func absentBattery() {
        for installed: Any in [false, NSNumber(value: 0)] {
            let reading = BatteryHealthParser.parse(["BatteryInstalled": installed], at: instant)
            switch reading {
            case .ok:
                Issue.record("An explicitly absent battery must not produce a value")
            case let .unavailable(reason):
                #expect(!reason.isEmpty)
            case let .failed(reason):
                Issue.record("An explicitly absent battery is unavailable, not failed: \(reason)")
            }
        }
    }

    @Test("Required battery fields fail closed")
    func requiredFieldsFailClosed() {
        let invalidProperties: [[String: Any]] = [
            ["DesignCapacity": 8_694, "NominalChargeCapacity": 6_768],
            ["CycleCount": -1, "DesignCapacity": 8_694, "NominalChargeCapacity": 6_768],
            ["CycleCount": 1.5, "DesignCapacity": 8_694, "NominalChargeCapacity": 6_768],
            ["CycleCount": "909", "DesignCapacity": 8_694, "NominalChargeCapacity": 6_768],
            ["CycleCount": 909, "NominalChargeCapacity": 6_768],
            ["CycleCount": 909, "DesignCapacity": 0, "NominalChargeCapacity": 6_768],
            ["CycleCount": 909, "DesignCapacity": -1, "NominalChargeCapacity": 6_768],
            ["CycleCount": 909, "DesignCapacity": 8_694.5, "NominalChargeCapacity": 6_768],
            ["CycleCount": 909, "DesignCapacity": "8694", "NominalChargeCapacity": 6_768],
        ]

        for properties in invalidProperties {
            expectFailure(BatteryHealthParser.parse(properties, at: instant))
        }
    }

    @Test("Capacity sources use the specified precedence and eligibility")
    func capacitySourcePrecedence() throws {
        let nominal = try batteryValue([
            "CycleCount": 909,
            "DesignCapacity": 8_694,
            "NominalChargeCapacity": 6_768,
            "AppleRawMaxCapacity": 8_000,
            "MaxCapacity": 8_500,
        ])
        #expect(nominal.maximumCapacityPercent == 78)

        let rawFallback = try batteryValue([
            "CycleCount": 10,
            "DesignCapacity": 8_000,
            "NominalChargeCapacity": 0,
            "AppleRawMaxCapacity": 6_000,
            "MaxCapacity": 7_000,
        ])
        #expect(rawFallback.maximumCapacityPercent == 75)

        let intelFallback = try batteryValue([
            "CycleCount": 10,
            "DesignCapacity": 8_000,
            "AppleRawMaxCapacity": -1,
            "MaxCapacity": 4_000,
        ])
        #expect(intelFallback.maximumCapacityPercent == 50)

        expectFailure(BatteryHealthParser.parse([
            "CycleCount": 10,
            "DesignCapacity": 8_000,
            "MaxCapacity": 100,
        ], at: instant))
        expectFailure(BatteryHealthParser.parse([
            "CycleCount": 10,
            "DesignCapacity": 8_000,
            "NominalChargeCapacity": 0,
            "AppleRawMaxCapacity": 0,
        ], at: instant))
    }

    @Test("Capacity rounds half up and clamps to its valid range")
    func capacityRoundingAndClamping() throws {
        let half = try batteryValue([
            "CycleCount": 0,
            "DesignCapacity": 8,
            "NominalChargeCapacity": 1,
        ])
        #expect(half.maximumCapacityPercent == 13)

        let aboveDesign = try batteryValue([
            "CycleCount": 1,
            "DesignCapacity": 8_694,
            "NominalChargeCapacity": 9_000,
        ])
        #expect(aboveDesign.maximumCapacityPercent == 100)

        let almostEmpty = try batteryValue([
            "CycleCount": 1,
            "DesignCapacity": 1_000,
            "NominalChargeCapacity": 1,
        ])
        #expect(almostEmpty.maximumCapacityPercent == 1)
    }

    @Test("Temperature and service condition follow registry semantics")
    func temperatureAndCondition() throws {
        let serviced = try batteryValue([
            "CycleCount": NSNumber(value: 909),
            "DesignCapacity": NSNumber(value: 8_694),
            "DesignCycleCount9C": NSNumber(value: 1_000),
            "NominalChargeCapacity": NSNumber(value: 6_768),
            "Temperature": NSNumber(value: 3_067),
            "PermanentFailureStatus": NSNumber(value: 2),
        ])
        #expect(serviced.cycleCount == 909)
        #expect(serviced.designCycleCount == 1_000)
        #expect(serviced.temperatureCelsius == 30.67)
        #expect(serviced.condition == .serviceRecommended)

        let invalidRatedCycles = try batteryValue([
            "CycleCount": 1,
            "DesignCapacity": 100,
            "DesignCycleCount9C": 0,
            "NominalChargeCapacity": 80,
        ])
        #expect(invalidRatedCycles.designCycleCount == nil)

        for rawTemperature in [-2_000, 10_000] {
            let boundary = try batteryValue([
                "CycleCount": 1,
                "DesignCapacity": 100,
                "NominalChargeCapacity": 80,
                "Temperature": rawTemperature,
            ])
            #expect(boundary.temperatureCelsius == Double(rawTemperature) / 100)
        }

        for temperature: Any? in [nil, "3067", -2_001, 10_001] {
            var properties: [String: Any] = [
                "CycleCount": 1,
                "DesignCapacity": 100,
                "NominalChargeCapacity": 80,
            ]
            if let temperature {
                properties["Temperature"] = temperature
            }
            let health = try batteryValue(properties)
            #expect(health.temperatureCelsius == nil)
            #expect(health.condition == .normal)
        }
    }

    @Test("A successful battery reading preserves source and timestamp")
    func readingMetadata() throws {
        let reading = BatteryHealthParser.parse([
            "CycleCount": 2,
            "DesignCapacity": 100,
            "NominalChargeCapacity": 80,
        ], at: instant)
        let (_, source, at) = try okValue(reading)
        #expect(source == "AppleSmartBattery")
        #expect(at == instant)
    }

    private func batteryValue(_ properties: [String: Any]) throws -> BatteryHealth {
        let (health, _, _) = try okValue(BatteryHealthParser.parse(properties, at: instant))
        return health
    }
}

@Suite("U15 SMC decoding")
struct SMCDecoderAcceptanceTests {
    @Test("All supported SMC encodings decode with the required byte order")
    func supportedTypes() {
        #expect(SMCDecoder.decode(type: "flt ", bytes: [0x00, 0x00, 0x48, 0x42]) == 50.0)
        #expect(SMCDecoder.decode(type: "ui8 ", bytes: [0xFE]) == 254.0)
        #expect(SMCDecoder.decode(type: "ui16", bytes: [0x08, 0x98]) == 2_200.0)
        #expect(SMCDecoder.decode(type: "ui32", bytes: [0x00, 0x01, 0x01, 0xD0]) == 66_000.0)
        #expect(SMCDecoder.decode(type: "sp78", bytes: [0x19, 0x80]) == 25.5)
        #expect(SMCDecoder.decode(type: "sp78", bytes: [0xFF, 0x80]) == -0.5)
    }

    @Test("Unknown types and exact byte-count mismatches are rejected")
    func invalidTypeAndLengths() {
        #expect(SMCDecoder.decode(type: "abcd", bytes: [0]) == nil)
        #expect(SMCDecoder.decode(type: "flt ", bytes: [0, 0, 0]) == nil)
        #expect(SMCDecoder.decode(type: "flt ", bytes: [0, 0, 0, 0, 0]) == nil)
        #expect(SMCDecoder.decode(type: "ui8 ", bytes: []) == nil)
        #expect(SMCDecoder.decode(type: "ui8 ", bytes: [1, 2]) == nil)
        #expect(SMCDecoder.decode(type: "ui16", bytes: [1]) == nil)
        #expect(SMCDecoder.decode(type: "ui32", bytes: [1, 2, 3]) == nil)
        #expect(SMCDecoder.decode(type: "sp78", bytes: [1, 2, 3]) == nil)
    }

    @Test("Non-finite float values are rejected")
    func nonFiniteFloat() {
        #expect(SMCDecoder.decode(type: "flt ", bytes: [0x00, 0x00, 0xC0, 0x7F]) == nil)
        #expect(SMCDecoder.decode(type: "flt ", bytes: [0x00, 0x00, 0x80, 0x7F]) == nil)
    }
}

@Suite("U15 thermal sensor summary")
struct ThermalSensorSummaryAcceptanceTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_123)

    @Test("Fan count is required and validated")
    func fanCountValidation() {
        for values: [String: Double] in [
            [:],
            ["FNum": -1],
            ["FNum": 1.5],
            ["FNum": 9],
        ] {
            expectFailure(ThermalSensorSummary.summarize(values, at: instant))
        }
    }

    @Test("A fanless Mac is a valid successful reading")
    func fanlessMac() throws {
        let (sensors, source, at) = try okValue(ThermalSensorSummary.summarize([
            "FNum": 0,
        ], at: instant))
        #expect(sensors.fans.isEmpty)
        #expect(sensors.hottestCelsius == nil)
        #expect(sensors.hottestSensor == nil)
        #expect(sensors.sensorCount == 0)
        #expect(source == "AppleSMC")
        #expect(at == instant)
    }

    @Test("Every declared fan needs a nonnegative current speed")
    func requiredFanSpeeds() {
        expectFailure(ThermalSensorSummary.summarize(["FNum": 1], at: instant))
        expectFailure(ThermalSensorSummary.summarize([
            "FNum": 1,
            "F0Ac": -1,
        ], at: instant))
        expectFailure(ThermalSensorSummary.summarize([
            "FNum": 2,
            "F0Ac": 1_000,
        ], at: instant))
    }

    @Test("Fan speeds round and optional limits require positive values")
    func fanValues() throws {
        let (sensors, _, _) = try okValue(ThermalSensorSummary.summarize([
            "FNum": 2,
            "F0Ac": 1_800.6,
            "F0Mn": 1_200.4,
            "F0Mx": 5_500.6,
            "F1Ac": 2_200.4,
            "F1Mn": 0,
            "F1Mx": -1,
        ], at: instant))
        #expect(sensors.fans == [
            Fan(index: 0, rpm: 1_801, minimumRPM: 1_200, maximumRPM: 5_501),
            Fan(index: 1, rpm: 2_200, minimumRPM: nil, maximumRPM: nil),
        ])
    }

    @Test("Only exactly shaped plausible temperature keys are counted")
    func temperatureFiltering() throws {
        let (sensors, _, _) = try okValue(ThermalSensorSummary.summarize([
            "FNum": 0,
            "Tp01": 41.5,
            "Tg0P": 72,
            "TC0P": 72,
            "Ta9Z": 1.01,
            "Tb00": 1,
            "Tc00": -128,
            "Td00": 200,
            "Te00": .nan,
            "T001": 60,
            "TC0": 80,
            "Txyz12": 90,
            "F0Ac": 4_000,
        ], at: instant))
        #expect(sensors.sensorCount == 4)
        #expect(sensors.hottestCelsius == 72)
        #expect(sensors.hottestSensor == "TC0P")
    }

    @Test("No plausible temperature still produces a successful reading")
    func noPlausibleTemperature() throws {
        let (sensors, _, _) = try okValue(ThermalSensorSummary.summarize([
            "FNum": 0,
            "Tp01": 0,
            "Tg0P": 125.1,
        ], at: instant))
        #expect(sensors.sensorCount == 0)
        #expect(sensors.hottestCelsius == nil)
        #expect(sensors.hottestSensor == nil)
    }
}

@Suite("U15 plain wording")
struct PowerWordingAcceptanceTests {
    @Test("Battery wording includes capacity, cycles, rating, and service advice")
    func batteryWording() {
        let health = BatteryHealth(
            cycleCount: 909,
            designCycleCount: 1_000,
            maximumCapacityPercent: 78,
            temperatureCelsius: 30.67,
            condition: .serviceRecommended
        )
        let summary = PowerWording.batterySummary(health)
        #expect(!summary.isEmpty)
        #expect(summary.contains("78%"))
        #expect(summary.contains("909 of 1000"))
        #expect(summary.lowercased().contains("service"))
        #expect(summary.unicodeScalars.allSatisfy { $0.value < 128 })
    }

    @Test("Battery wording still contains the cycle count without a rating")
    func batteryWordingWithoutRating() {
        let health = BatteryHealth(
            cycleCount: 42,
            designCycleCount: nil,
            maximumCapacityPercent: 91,
            temperatureCelsius: nil,
            condition: .normal
        )
        let summary = PowerWording.batterySummary(health)
        #expect(!summary.isEmpty)
        #expect(summary.contains("91%"))
        #expect(summary.contains("42"))
        #expect(summary.unicodeScalars.allSatisfy { $0.value < 128 })
    }

    @Test("Fan wording distinguishes fanless Macs and lists every RPM")
    func fanWording() {
        let noFans = PowerWording.fanSummary(ThermalSensors(
            fans: [],
            hottestCelsius: nil,
            hottestSensor: nil,
            sensorCount: 0
        ))
        #expect(!noFans.isEmpty)
        #expect(noFans.lowercased().contains("no fans"))
        #expect(noFans.unicodeScalars.allSatisfy { $0.value < 128 })

        let fans = PowerWording.fanSummary(ThermalSensors(
            fans: [
                Fan(index: 0, rpm: 1_800, minimumRPM: 1_200, maximumRPM: 5_500),
                Fan(index: 1, rpm: 2_200, minimumRPM: nil, maximumRPM: nil),
            ],
            hottestCelsius: 72,
            hottestSensor: "TC0P",
            sensorCount: 1
        ))
        #expect(!fans.isEmpty)
        #expect(fans.contains("1800"))
        #expect(fans.contains("2200"))
        #expect(fans.unicodeScalars.allSatisfy { $0.value < 128 })
    }
}

private enum AcceptanceError: Error {
    case expectedSuccessfulReading
}

private func okValue<Value>(_ reading: Reading<Value>) throws -> (Value, String, Date) {
    switch reading {
    case let .ok(value, source, at):
        return (value, source, at)
    case let .unavailable(reason):
        Issue.record("Expected a successful reading, got unavailable: \(reason)")
        throw AcceptanceError.expectedSuccessfulReading
    case let .failed(reason):
        Issue.record("Expected a successful reading, got failed: \(reason)")
        throw AcceptanceError.expectedSuccessfulReading
    }
}

private func expectFailure<Value>(_ reading: Reading<Value>) {
    switch reading {
    case .ok:
        Issue.record("Invalid input must not produce a value")
    case let .unavailable(reason):
        Issue.record("Invalid input must fail rather than become unavailable: \(reason)")
    case let .failed(reason):
        #expect(!reason.isEmpty)
    }
}
