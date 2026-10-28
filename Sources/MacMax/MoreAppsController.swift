import AppKit
import MacMaxCore

/// A Mac app from Settings > More apps that Launch Services knows on this Mac.
struct InstalledCopy: Equatable {
    let url: URL
    /// Nil when its Info.plist names no version: shown as installed, compared with nothing.
    let version: String?
    /// The `git describe` a build from a checkout stamps (BtonSource, RMJSource). Such a build keeps the template's
    /// placeholder as its version, so only a describe that is exactly a release tag gives a version to compare.
    var source: String?

    init(url: URL, info: NSDictionary?, sourceKey: String?) {
        self.url = url
        let source = sourceKey.flatMap { info?[$0] as? String }?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        if let source {
            version = source.wholeMatch(of: /v?\d+\.\d+\.\d+/) != nil ? source : nil
        } else {
            version = info?["CFBundleShortVersionString"] as? String
        }
    }

    init(url: URL, version: String?, source: String? = nil) {
        self.url = url
        self.version = version
        self.source = source
    }
}

/// Settings > More apps' live part: the latest release of each app, asked when the pane opens and kept for six hours,
/// and the installed copy of each Mac app, read on every open.
@MainActor
final class MoreAppsController {
    private let model: PanelModel
    private var schedule = ReleaseCheckSchedule(now: Date(), interval: 6 * 3_600)
    private var checking = false
    /// The last check answered for every app. A partial answer is never served from the cache: the next open asks again
    /// once the 15-minute floor has passed.
    private var cacheComplete = false

    init(model: PanelModel) {
        self.model = model
        model.refreshMoreApps = { [weak self] byPress in self?.refresh(byPress: byPress) }
    }

    private func refresh(byPress: Bool) {
        readInstalled()
        let now = Date()
        guard !checking else { return }
        if !byPress, cacheComplete, schedule.nextAutomatic > now { return }
        guard byPress ? schedule.mayCheckByPress(at: now) : schedule.mayCheck(at: now) else {
            if byPress { model.moreAppsProblem = "GitHub asked MacMax to wait before checking again." }
            return
        }
        checking = true
        schedule.recordAttempt(at: now)
        model.moreAppsChecking = true
        model.moreAppsProblem = nil
        Task {
            let answers = await Self.fetchAll(userAgent: "MacMax/\(model.runningVersion)")
            apply(answers)
            checking = false
            model.moreAppsChecking = false
        }
    }

    private static func fetchAll(userAgent: String) async -> [String: LatestReleaseAnswer] {
        await withTaskGroup(of: (String, LatestReleaseAnswer).self) { group in
            for app in MoreApp.all {
                group.addTask { (app.repo, await GitHubReleases.latest(repo: app.repo, userAgent: userAgent)) }
            }
            var answers: [String: LatestReleaseAnswer] = [:]
            for await (repo, answer) in group { answers[repo] = answer }
            return answers
        }
    }

    /// Every answer replaces the last one: a failed read shows as unknown, never as the release seen hours ago.
    private func apply(_ answers: [String: LatestReleaseAnswer]) {
        let now = Date()
        model.moreAppReleases = answers
        model.moreAppsCheckedAt = now
        var limited = false, failed = false
        var longestPause: TimeInterval?
        for answer in answers.values {
            switch answer {
            case let .rateLimited(retryAfter):
                limited = true
                // No Retry-After counts as the schedule's own one-hour default, so it is not outweighed by a shorter one.
                longestPause = max(longestPause ?? 0, retryAfter ?? 3_600)
            case .failed: failed = true
            case .release, .none: break
            }
        }
        cacheComplete = !limited && !failed
        if limited {
            schedule.recordRateLimit(at: now, retryAfter: longestPause)
            model.moreAppsProblem = "GitHub asked MacMax to wait, so some versions are unknown for now."
        } else if failed {
            // Not a success: the next open asks again once the 15-minute floor has passed.
            model.moreAppsProblem = "Some versions could not be read from GitHub."
        } else {
            schedule.recordSuccess(at: now)
        }
    }

    private func readInstalled() {
        var found: [String: InstalledCopy] = [:]
        for app in MoreApp.all {
            guard let bundleID = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            // Read from disk each time: Bundle caches its Info.plist, so an update made while MacMax runs would not show.
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            found[bundleID] = InstalledCopy(url: url, info: info, sourceKey: app.sourceKey)
        }
        model.moreAppsInstalled = found
    }
}
