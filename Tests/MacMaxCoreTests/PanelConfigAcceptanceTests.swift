import Foundation
import Testing
@testable import MacMaxCore

private struct TemporaryPanelHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMax-PanelConfig-\(UUID().uuidString)", isDirectory: true)
    }

    var home: MacMaxHome { MacMaxHome(environment: ["MACMAX_HOME": url.path]) }
    var configURL: URL { url.appendingPathComponent("config.json") }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func writeJSON(_ object: Any, to temporary: TemporaryPanelHome) throws {
    try FileManager.default.createDirectory(at: temporary.url, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: temporary.configURL)
}

private func loadedConfig(from store: ConfigStore) throws -> PanelConfig {
    switch store.load() {
    case let .ok(config): return config
    case let .malformed(reason):
        Issue.record("Expected valid config, got malformed: \(reason)")
        return .default
    }
}

private func assertMalformedUpdatePreserves(_ bytes: Data) throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    try FileManager.default.createDirectory(at: temporary.url, withIntermediateDirectories: true)
    try bytes.write(to: temporary.configURL)
    let store = ConfigStore(home: temporary.home)

    guard case .malformed = store.load() else {
        Issue.record("Malformed config loaded as valid")
        return
    }
    do {
        _ = try store.update { $0.samplingSeconds = 60 }
        Issue.record("Updating malformed config did not throw")
    } catch let error as ConfigError {
        guard case .malformed = error else {
            Issue.record("Expected ConfigError.malformed, got \(error)")
            return
        }
    }
    #expect(try Data(contentsOf: temporary.configURL) == bytes)
}

@Test("Panel config has conservative documented defaults")
func panelConfigDefaults() {
    let config = PanelConfig.default
    #expect(config.samplingSeconds == 10)
    #expect(config.menuBarText == .none)
    #expect(config.auditEveryHours == 4)
    #expect(config.auditOnCriticalPressure)
    #expect(config.notifyOn == .critOnly)
    #expect(!config.ipCheckEnabled)
    #expect(config.ipEndpoint == nil)
    #expect(config.thresholds.isEmpty)
    #expect(config.disabledRules.isEmpty)
    #expect(config.lookName == nil)
}

@Test("An absent config file loads defaults without creating files")
func absentConfigLoadsDefaults() throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }

    #expect(ConfigStore(home: temporary.home).load() == .ok(.default))
    #expect(!FileManager.default.fileExists(atPath: temporary.url.path))
}

@Test("Load bounds every configurable field and ignores unknown JSON keys")
func loadBoundsEveryField() throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    let thresholds = RuleSet.all.flatMap(\.thresholds)
    let low = try #require(thresholds.first)
    let high = try #require(thresholds.dropFirst().first)
    try writeJSON([
        "sampling_seconds": 7,
        "menu_bar_text": "cpu",
        "audit_every_hours": 3,
        "audit_on_critical_pressure": false,
        "notify_on": "warnAndCrit",
        "ip_check_enabled": true,
        "ip_endpoint": "http://user:secret@example.invalid/check",
        "thresholds": [
            low.key: low.range.lowerBound - 1_000,
            high.key: high.range.upperBound + 1_000,
            "T_NOT_A_RULE": 42,
        ],
        "disabled_rules": [RuleSet.all[1].id, "not_a_rule", RuleSet.all[0].id, RuleSet.all[1].id],
        "look_name": "Solid Glass",
        "unknown_key": "ignored",
    ], to: temporary)

    let config = try loadedConfig(from: ConfigStore(home: temporary.home))
    #expect(config.samplingSeconds == 10)
    #expect(config.menuBarText == .cpu)
    #expect(config.auditEveryHours == 4)
    #expect(!config.auditOnCriticalPressure)
    #expect(config.notifyOn == .warnAndCrit)
    #expect(config.ipCheckEnabled)
    #expect(config.ipEndpoint == nil)
    #expect(config.thresholds == [low.key: low.range.lowerBound, high.key: high.range.upperBound])
    #expect(config.disabledRules == [RuleSet.all[0].id, RuleSet.all[1].id].sorted())
    #expect(config.lookName == "Solid Glass")
}

@Test("Invalid endpoint forms are cleared on load")
func loadClearsInvalidEndpoints() throws {
    let threshold = try #require(RuleSet.all.flatMap(\.thresholds).first)
    for endpoint in ["not a URL", "https:///missing-host", "https://user@example.com/check"] {
        let temporary = try TemporaryPanelHome()
        defer { temporary.remove() }
        try FileManager.default.createDirectory(at: temporary.url, withIntermediateDirectories: true)
        let json = """
        {"ip_endpoint":"\(endpoint)","thresholds":{"\(threshold.key)":\(threshold.defaultValue)}}
        """
        try Data(json.utf8).write(to: temporary.configURL, options: .atomic)
        let config = try loadedConfig(from: ConfigStore(home: temporary.home))
        #expect(config.ipEndpoint == nil)
        #expect(config.thresholds[threshold.key] == threshold.defaultValue)
    }
}

@Test("Non-finite threshold changes are dropped before writing")
func updateDropsNonFiniteThresholds() throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    let thresholds = RuleSet.all.flatMap(\.thresholds)
    let nan = try #require(thresholds.first)
    let infinity = try #require(thresholds.dropFirst().first)

    let config = try ConfigStore(home: temporary.home).update {
        $0.thresholds = [nan.key: .nan, infinity.key: .infinity]
    }
    #expect(config.thresholds.isEmpty)
    #expect(try loadedConfig(from: ConfigStore(home: temporary.home)).thresholds.isEmpty)
}

@Test("Missing JSON keys take defaults and a valid HTTPS endpoint survives")
func missingKeysDefaultAndValidEndpointSurvives() throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    try writeJSON(["ip_endpoint": "https://example.com/check"], to: temporary)

    var expected = PanelConfig.default
    expected.ipEndpoint = "https://example.com/check"
    #expect(ConfigStore(home: temporary.home).load() == .ok(expected))
}

@Test("Truncated JSON fails closed and update preserves its bytes")
func truncatedJSONFailsClosed() throws {
    try assertMalformedUpdatePreserves(Data(#"{"sampling_seconds":10"#.utf8))
}

@Test("A wrong JSON value type fails closed and update preserves its bytes")
func wrongTypeFailsClosed() throws {
    try assertMalformedUpdatePreserves(Data(#"{"sampling_seconds":"ten"}"#.utf8))
}

@Test("Update re-reads a hand edit made after an earlier load")
func updateRereadsHandEdit() throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    let store = ConfigStore(home: temporary.home)
    _ = try store.update { $0.samplingSeconds = 5 }
    _ = store.load()
    var handEdited = try loadedConfig(from: store)
    handEdited.menuBarText = .network
    let editedData = try JSONEncoder.panelConfigEncoder.encode(handEdited)
    try editedData.write(to: temporary.configURL, options: .atomic)

    let updated = try store.update { $0.auditEveryHours = 24 }
    #expect(updated.menuBarText == .network)
    #expect(updated.auditEveryHours == 24)
}

@Test("Update creates a private home and config file")
func updateCreatesPrivateFiles() throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    _ = try ConfigStore(home: temporary.home).update { $0.samplingSeconds = 30 }

    let directory = try FileManager.default.attributesOfItem(atPath: temporary.url.path)
    let file = try FileManager.default.attributesOfItem(atPath: temporary.configURL.path)
    #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test("An unchanged update does not rewrite the config file")
func unchangedUpdateDoesNotRewrite() throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    let store = ConfigStore(home: temporary.home)
    _ = try store.update { _ in }
    let oldDate = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: temporary.configURL.path)

    _ = try store.update { _ in }
    let attributes = try FileManager.default.attributesOfItem(atPath: temporary.configURL.path)
    #expect(attributes[.modificationDate] as? Date == oldDate)
}

@Test("Config round trips with sorted snake-case keys")
func configRoundTripAndEncodingShape() throws {
    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    let threshold = try #require(RuleSet.all.flatMap(\.thresholds).first)
    let store = ConfigStore(home: temporary.home)
    let written = try store.update {
        $0.samplingSeconds = 60
        $0.menuBarText = .country
        $0.auditEveryHours = 0
        $0.auditOnCriticalPressure = false
        $0.notifyOn = .never
        $0.ipCheckEnabled = true
        $0.ipEndpoint = "https://example.com/ip"
        $0.thresholds = [threshold.key: threshold.defaultValue]
        $0.disabledRules = [RuleSet.all[0].id]
        $0.lookName = "Solid Glass Light"
    }

    #expect(store.load() == .ok(written))
    let text = try String(contentsOf: temporary.configURL, encoding: .utf8)
    #expect(text.contains("\"sampling_seconds\""))
    #expect(text.contains("\"audit_on_critical_pressure\""))
    #expect(!text.contains("samplingSeconds"))
    let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(Set(object.keys) == [
        "sampling_seconds", "menu_bar_text", "audit_every_hours", "audit_on_critical_pressure",
        "notify_on", "ip_check_enabled", "ip_endpoint", "thresholds", "disabled_rules", "look_name",
        "protected_paths",
    ])
    let orderedKeys = object.keys.sorted()
    let positions = try orderedKeys.map { key in
        try #require(text.range(of: "\"\(key)\"")?.lowerBound)
    }
    #expect(positions == positions.sorted())
}

@Test("Protected cleanup paths are bounded, sorted, and persisted")
func protectedPathsAreBoundedAndPersisted() throws {
    #expect(PanelConfig.default.protectedPaths == [])

    let temporary = try TemporaryPanelHome()
    defer { temporary.remove() }
    try writeJSON(["protected_paths": ["/b", "relative", "/a", "/b", ""]], to: temporary)
    let store = ConfigStore(home: temporary.home)

    #expect(try loadedConfig(from: store).protectedPaths == ["/a", "/b"])
    let updated = try store.update { $0.protectedPaths.append("/c") }
    #expect(updated.protectedPaths == ["/a", "/b", "/c"])
    #expect(try loadedConfig(from: ConfigStore(home: temporary.home)).protectedPaths == ["/a", "/b", "/c"])
}

private extension JSONEncoder {
    static var panelConfigEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
