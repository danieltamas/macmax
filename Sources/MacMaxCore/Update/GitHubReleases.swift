import Foundation

/// One `releases/latest` answer. Three outcomes besides a release, so "no release yet" is never read as a failure and a
/// failure is never read as "no release".
public enum LatestReleaseAnswer: Sendable, Equatable {
    case release(ReleaseInfo)
    /// GitHub answered 404: the repository has no published release yet.
    case none
    /// GitHub answered 403 or 429; the delay from Retry-After when it gave one.
    case rateLimited(retryAfter: TimeInterval?)
    case failed(reason: String)
}

/// GitHub's latest release for a repository, unauthenticated: MacMax's own update check and Settings > More apps.
public enum GitHubReleases {
    public static func endpoint(repo: String) -> URL? {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..",
                  part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
    }

    public static func classify(status: Int, body: Data, retryAfter: String?, now: Date = Date()) -> LatestReleaseAnswer {
        switch status {
        case 200:
            switch ReleaseParser.parse(body, now: now) {
            case let .ok(info, _, _): return .release(info)
            case let .unavailable(reason), let .failed(reason): return .failed(reason: reason)
            }
        case 404: return .none
        case 403, 429: return .rateLimited(retryAfter: retryDelay(retryAfter, now: now))
        default: return .failed(reason: "GitHub answered \(status).")
        }
    }

    /// Retry-After is whole seconds or an HTTP date.
    public static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = TimeInterval(text) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text).map { $0.timeIntervalSince(now) }
    }

    public static func latest(repo: String, userAgent: String) async -> LatestReleaseAnswer {
        guard let url = endpoint(repo: repo) else { return .failed(reason: "\(repo) is not a GitHub repository name.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed(reason: "The answer was not HTTP.") }
            return classify(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return .failed(reason: "GitHub could not be reached.")
        }
    }
}

/// An installed app against the latest release.
public enum InstalledStanding: Sendable, Equatable {
    case notInstalled
    case current
    /// The installed copy is older; latest is the release's version as X.Y.Z.
    case behind(latest: String)
    case ahead
    /// Installed, but its version or the latest tag is missing or not X.Y.Z: no claim either way.
    case unknown

    public static func compare(isInstalled: Bool, installedVersion: String?, latestTag: String?) -> InstalledStanding {
        guard isInstalled else { return .notInstalled }
        guard let installed = SemanticVersion.parse(installedVersion), let latest = SemanticVersion.parse(latestTag) else { return .unknown }
        if installed.lexicographicallyPrecedes(latest) { return .behind(latest: SemanticVersion.text(latest)) }
        if latest.lexicographicallyPrecedes(installed) { return .ahead }
        return .current
    }
}
