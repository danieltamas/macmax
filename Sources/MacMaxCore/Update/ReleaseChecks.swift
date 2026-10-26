import Foundation

public struct ReleaseInfo: Sendable, Equatable {
    public let tag: String
    public let version: String
    public let htmlURL: String?
}

public enum ReleaseParser {
    /// GitHub's `releases/latest` body. Anything that is not a published release with a clean `X.Y.Z` tag is not a
    /// release to offer.
    public static func parse(_ data: Data, now: Date = Date()) -> Reading<ReleaseInfo> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed(reason: "the release answer is not JSON")
        }
        guard let tag = object["tag_name"] as? String else { return .unavailable(reason: "the release has no tag") }
        guard let numbers = SemanticVersion.parse(tag) else { return .failed(reason: "the release tag is not X.Y.Z") }
        if (object["draft"] as? Bool) == true || (object["prerelease"] as? Bool) == true {
            return .unavailable(reason: "the newest release is not published as final")
        }
        var link: String?
        if let text = object["html_url"] as? String, let url = URL(string: text), url.scheme == "https", url.host == "github.com" {
            link = text
        }
        let version = SemanticVersion.text(numbers)
        return .ok(ReleaseInfo(tag: tag.trimmingCharacters(in: .whitespacesAndNewlines), version: version, htmlURL: link), source: "github", at: now)
    }
}

/// When a release check may run: at launch and every 24 hours, never twice within 15 minutes, and not while GitHub
/// has asked for a pause.
public struct ReleaseCheckSchedule: Sendable, Equatable {
    static let floor: TimeInterval = 15 * 60
    static let day: TimeInterval = 24 * 3_600

    private var lastAttempt: Date?
    private var blockedUntil: Date?
    public private(set) var nextAutomatic: Date

    public init(now: Date) { nextAutomatic = now }

    public func mayCheck(at date: Date) -> Bool {
        if let lastAttempt, date < lastAttempt.addingTimeInterval(Self.floor) { return false }
        if let blockedUntil, date < blockedUntil { return false }
        return true
    }

    /// A press on "Check again" is the owner asking, so the 15-minute floor does not apply; GitHub's pause still does.
    public func mayCheckByPress(at date: Date) -> Bool {
        if let blockedUntil, date < blockedUntil { return false }
        return true
    }

    public mutating func recordAttempt(at date: Date) { lastAttempt = date }

    public mutating func recordSuccess(at date: Date) {
        lastAttempt = date
        blockedUntil = nil
        nextAutomatic = date.addingTimeInterval(Self.day)
    }

    /// GitHub answered 403 or 429. Waits as long as it asked, at least 15 minutes and an hour when it did not say, at most a day.
    public mutating func recordRateLimit(at date: Date, retryAfter: TimeInterval?) {
        let wait = min(Self.day, max(Self.floor, retryAfter.flatMap { $0.isFinite ? $0 : nil } ?? 3_600))
        lastAttempt = date
        blockedUntil = date.addingTimeInterval(wait)
        nextAutomatic = blockedUntil ?? date
    }
}
