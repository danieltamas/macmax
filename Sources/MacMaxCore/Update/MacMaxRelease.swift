import Foundation

public enum Standing: Sendable, Equatable { case behind, latest, ahead, unknown }

/// `X.Y.Z` and nothing else: a tag that feeds an installer's argument must be exactly this.
enum SemanticVersion {
    static func parse(_ text: String?) -> [Int]? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    static func text(_ numbers: [Int]) -> String { numbers.map(String.init).joined(separator: ".") }
}

public enum MacMaxRelease {
    /// Where this build stands against the newest release. `source` is the build's `git describe --tags --always --dirty`:
    /// the running version equals the tag only when nothing was added after it.
    public static func standing(version: String, source: String?, latestTag: String?) -> Standing {
        guard let running = SemanticVersion.parse(version), let latest = SemanticVersion.parse(latestTag) else { return .unknown }
        if running.lexicographicallyPrecedes(latest) { return .behind }
        if latest.lexicographicallyPrecedes(running) { return .ahead }
        let clean = source == nil || source?.trimmingCharacters(in: .whitespacesAndNewlines) == "v" + SemanticVersion.text(running)
        return clean ? .latest : .ahead
    }
}

public enum UpdateOffer {
    /// Exactly `/Applications/MacMax.app` or `<home>/Applications/MacMax.app`: a copy run from Downloads or a build
    /// folder is never replaced.
    public static func isInstalledLocation(bundlePath: String, home: String) -> Bool {
        bundlePath == "/Applications/MacMax.app" || bundlePath == home + "/Applications/MacMax.app"
    }

    /// The version to install, only when every gate is open.
    public static func version(standing: Standing, installed: Bool, latestTag: String?) -> String? {
        guard standing == .behind, installed, let numbers = SemanticVersion.parse(latestTag) else { return nil }
        return SemanticVersion.text(numbers)
    }
}
