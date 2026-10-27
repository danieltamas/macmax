import Testing
@testable import MacMaxCore

@Suite("U15 named sensors")
struct SensorCatalogAcceptanceTests {
    private let m1: [(String, String, SensorGroup)] = [
        ("Tp09", "CPU efficiency core 1", .cpu), ("Tp0T", "CPU efficiency core 2", .cpu),
        ("Tp01", "CPU performance core 1", .cpu), ("Tp05", "CPU performance core 2", .cpu),
        ("Tp0D", "CPU performance core 3", .cpu), ("Tp0H", "CPU performance core 4", .cpu),
        ("Tp0L", "CPU performance core 5", .cpu), ("Tp0P", "CPU performance core 6", .cpu),
        ("Tp0X", "CPU performance core 7", .cpu), ("Tp0b", "CPU performance core 8", .cpu),
        ("Tg05", "GPU 1", .gpu), ("Tg0D", "GPU 2", .gpu),
        ("Tg0L", "GPU 3", .gpu), ("Tg0T", "GPU 4", .gpu),
        ("Tm02", "Memory 1", .memory), ("Tm06", "Memory 2", .memory),
        ("Tm08", "Memory 3", .memory), ("Tm09", "Memory 4", .memory),
    ]

    private let m2: [(String, String)] = [
        ("Tp1h", "CPU efficiency core 1"), ("Tp1t", "CPU efficiency core 2"),
        ("Tp1p", "CPU efficiency core 3"), ("Tp1l", "CPU efficiency core 4"),
        ("Tp01", "CPU performance core 1"), ("Tp05", "CPU performance core 2"),
        ("Tp09", "CPU performance core 3"), ("Tp0D", "CPU performance core 4"),
        ("Tp0X", "CPU performance core 5"), ("Tp0b", "CPU performance core 6"),
        ("Tp0f", "CPU performance core 7"), ("Tp0j", "CPU performance core 8"),
        ("Tg0f", "GPU 1"), ("Tg0j", "GPU 2"),
    ]

    @Test("Every M1 sensor is named in catalog order")
    func m1SensorsAreNamedInOrder() {
        let sensors = SensorCatalog.name(values(m1.map(\.0)))
        #expect(sensors == m1.map { NamedSensor(key: $0.0, name: $0.1, group: $0.2, unit: .celsius, value: 60) })
        #expect(sensors.map(\.group) == Array(repeating: .cpu, count: 10)
            + Array(repeating: .gpu, count: 4) + Array(repeating: .memory, count: 4))
    }

    @Test("Keys outside the allowlist are never named")
    func unknownKeysAreNeverNamed() {
        let sensors = SensorCatalog.name(["Ta05": 8.5, "TCMz": 109, "VBUS": 16_777_216])
        #expect(sensors.isEmpty)
    }

    @Test("A generation below half is omitted while generic sensors remain")
    func generationBelowHalfIsOmitted() {
        var readings = values(Array(m1.prefix(8)).map(\.0))
        readings["TW0P"] = 50
        readings["TB1T"] = 40
        let sensors = SensorCatalog.name(readings)
        #expect(sensors.map(\.key) == ["TW0P", "TB1T"])
        #expect(sensors.allSatisfy { ![SensorGroup.cpu, .gpu, .memory].contains($0.group) })
    }

    @Test("Exactly half of the M1 list qualifies")
    func exactlyHalfQualifies() {
        let keys = Array(m1.prefix(9)).map(\.0)
        #expect(SensorCatalog.name(values(keys)).map(\.key) == keys)
    }

    @Test("The qualifying generation with the most plausible keys wins")
    func bestGenerationWins() throws {
        let allReadings = values(Set(m1.map(\.0) + m2.map(\.0)))
        #expect(SensorCatalog.name(allReadings).map(\.key) == m1.map(\.0))

        var m2Wins = values(m2.map(\.0))
        for key in ["Tp0T", "Tp0H", "Tp0L"] { m2Wins[key] = 60 }
        let sensors = SensorCatalog.name(m2Wins)
        #expect(sensors.map(\.key) == m2.map(\.0))
        #expect(try #require(sensors.first { $0.key == "Tp01" }).name == "CPU performance core 1")
        #expect(try #require(sensors.first { $0.key == "Tp05" }).name == "CPU performance core 2")
    }

    @Test("A tie chooses the earlier generation list")
    func tieChoosesEarlierList() {
        let m1Only = ["Tp0T", "Tp0H", "Tp0L", "Tp0P", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        let m2Only = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j", "Tg0f", "Tg0j"]
        let sensors = SensorCatalog.name(values(m1Only + m2Only + ["Tp01"]))
        #expect(sensors.map(\.key) == ["Tp0T", "Tp01", "Tp0H", "Tp0L", "Tp0P", "Tg05", "Tg0D", "Tg0L", "Tg0T"])
        #expect(sensors.first { $0.key == "Tp01" }?.name == "CPU performance core 1")
    }

    @Test("Each sensor unit accepts only plausible values")
    func plausibilityBoundaries() {
        let temperatures = SensorCatalog.name([
            "TW0P": 0, "TH0x": 1, "TB1T": 125.5, "TB2T": -3, "TaLP": 1.1, "TaRF": 125,
        ])
        #expect(temperatures.map(\.key) == ["TaLP", "TaRF"])
        #expect(temperatures.map(\.value) == [1.1, 125])

        let power = SensorCatalog.name(["VD0R": 0, "ID0R": 0, "PDTR": 1_000, "PSTR": 999])
        #expect(power.map(\.key) == ["ID0R", "PSTR"])
        #expect(power.map(\.value) == [0, 999])
    }

    @Test("Electrical sensors appear by name only when they read")
    func electricalSensorsAppearOnlyWhenRead() {
        let sensors = SensorCatalog.name(["VD0R": 27.5, "ID0R": 1.01, "PDTR": 28])
        #expect(sensors == [
            NamedSensor(key: "VD0R", name: "DC in", group: .power, unit: .volts, value: 27.5),
            NamedSensor(key: "ID0R", name: "DC in", group: .power, unit: .amps, value: 1.01),
            NamedSensor(key: "PDTR", name: "DC in", group: .power, unit: .watts, value: 28),
        ])
        #expect(!sensors.contains { $0.name == "Thunderbolt right" || $0.value == 0 })
    }

    @Test("Groups follow group order and summarize their temperature sensors")
    func groupsAreOrderedAndSummarized() throws {
        let cpuFirst = NamedSensor(key: "a", name: "First", group: .cpu, unit: .celsius, value: 60)
        let power = NamedSensor(key: "b", name: "Power", group: .power, unit: .watts, value: 20)
        let cpuSecond = NamedSensor(key: "c", name: "Second", group: .cpu, unit: .celsius, value: 80)
        let cpuThird = NamedSensor(key: "d", name: "Third", group: .cpu, unit: .celsius, value: 70)
        let summaries = SensorCatalog.groups([power, cpuFirst, cpuSecond, cpuThird])
        #expect(summaries.map(\.group) == [.cpu, .power])
        let cpu = try #require(summaries.first)
        #expect(cpu.sensors == [cpuFirst, cpuSecond, cpuThird])
        #expect(cpu.hottestCelsius == 80)
        #expect(cpu.averageCelsius == 70)
        let powerSummary = try #require(summaries.last)
        #expect(powerSummary.sensors == [power])
        #expect(powerSummary.hottestCelsius == nil)
        #expect(powerSummary.averageCelsius == nil)
    }

    @Test("The catalog contains every listed key and no unknown examples")
    func allKeysMatchesTheCatalog() {
        let m3 = "Te05 Te0L Te0P Te0S Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E Tf14 Tf18 Tf19 Tf1A Tf24 Tf28 Tf29 Tf2A".split(separator: " ").map(String.init)
        let m4 = "Te05 Te0S Te09 Te0H Tp01 Tp05 Tp09 Tp0D Tp0V Tp0Y Tp0b Tp0e Tg0G Tg0H Tg1U Tg1k Tg0K Tg0L Tg0d Tg0e Tm0p Tm1p Tm2p".split(separator: " ").map(String.init)
        let generic = ["TW0P", "TH0x", "TB1T", "TB2T", "TaLP", "TaRF"]
        let electrical = ["VD0R", "ID0R", "PDTR", "VP0R", "IU1R", "IU2R", "IDBR", "PPBR", "PSTR"]
        let expected = Set(m1.map(\.0) + m2.map(\.0) + m3 + m4 + generic + electrical)
        #expect(SensorCatalog.allKeys == expected)
        #expect(["Ta05", "TCMz", "VBUS", "FNum"].allSatisfy { !SensorCatalog.allKeys.contains($0) })
    }

    @Test("Thermal sensors default to no named sensors and preserve supplied sensors")
    func thermalSensorsNamedField() {
        let defaulted = ThermalSensors(fans: [], hottestCelsius: nil, hottestSensor: nil, sensorCount: 0)
        #expect(defaulted.named.isEmpty)
        let named = NamedSensor(key: "TW0P", name: "Wireless chip", group: .wireless, unit: .celsius, value: 45)
        let supplied = ThermalSensors(fans: [], hottestCelsius: 45, hottestSensor: "TW0P", sensorCount: 1, named: [named])
        #expect(supplied.named == [named])
    }

    @Test("Cluster load separates efficiency cores from performance cores")
    func clusterBusySeparatesCoreTypes() {
        let live = SystemLive(coreBusyPercent: [100, 100, 20, 20, 20, 20], gpuPercent: nil,
                              memoryUsedBytes: nil, memoryTotalBytes: nil)
        #expect(live.clusterBusy(efficiencyCores: 2).efficiency == 100)
        #expect(live.clusterBusy(efficiencyCores: 2).performance == 20)
        for invalid in [nil, 0, 6, 7] as [Int?] {
            #expect(live.clusterBusy(efficiencyCores: invalid).efficiency == nil)
            #expect(live.clusterBusy(efficiencyCores: invalid).performance == nil)
        }

        let uneven = SystemLive(coreBusyPercent: [40, 10, 20], gpuPercent: nil,
                                memoryUsedBytes: nil, memoryTotalBytes: nil)
        #expect(uneven.clusterBusy(efficiencyCores: 1).efficiency == 40)
        #expect(uneven.clusterBusy(efficiencyCores: 1).performance == 15)
    }

    private func values<S: Sequence>(_ keys: S) -> [String: Double] where S.Element == String {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, 60) })
    }
}
