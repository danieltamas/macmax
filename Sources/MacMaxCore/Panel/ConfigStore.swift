import Foundation

public enum ConfigLoad: Sendable, Equatable {
    case ok(PanelConfig)
    /// The file exists and does not parse. It is never overwritten: the owner fixes or removes it.
    case malformed(reason: String)
}

public enum ConfigError: Error, Equatable { case malformed(String), unwritable(String) }

/// Reads and writes `<home>/config.json`. Every write re-reads the file first, so a hand edit is never lost,
/// and a file that does not parse stops the write instead of being replaced.
public struct ConfigStore: Sendable {
    private let home: MacMaxHome
    private var file: URL { home.url.appendingPathComponent("config.json") }

    public init(home: MacMaxHome) { self.home = home }

    public func load() -> ConfigLoad {
        do { return .ok(try read().config) } catch ConfigError.malformed(let reason) { return .malformed(reason: reason) }
        catch { return .malformed(reason: "config.json could not be read") }
    }

    @discardableResult
    public func update(_ change: (inout PanelConfig) -> Void) throws -> PanelConfig {
        let current = try read()
        var config = current.config
        change(&config)
        config = config.bounded()
        let data: Data
        do { data = try Self.encoder.encode(config) } catch { throw ConfigError.unwritable("config could not be encoded") }
        if data == current.bytes { return config }
        do {
            try home.prepare()
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { throw ConfigError.unwritable("config.json could not be written") }
        return config
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private func read() throws -> (config: PanelConfig, bytes: Data?) {
        let bytes: Data
        do { bytes = try Data(contentsOf: file) } catch {
            let code = (error as NSError).code
            if code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError { return (.default, nil) }
            throw ConfigError.malformed("config.json could not be read")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return (try decoder.decode(PanelConfig.self, from: bytes).bounded(), bytes) }
        catch { throw ConfigError.malformed("config.json is not valid") }
    }
}
