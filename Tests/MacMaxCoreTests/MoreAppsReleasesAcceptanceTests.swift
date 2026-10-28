import Foundation
import Testing
@testable import MacMaxCore

private func moreAppsReleaseBody(
    tag: String = "v1.4.2",
    prerelease: Bool = false,
    publication: String = "\"2026-10-20T09:30:00Z\""
) -> Data {
    Data("""
    {"tag_name":"\(tag)","draft":false,"prerelease":\(prerelease),
    "html_url":"https://github.com/example/app/releases/tag/v1.4.2"\(publication.isEmpty ? "" : ",\"published_at\":\(publication)")}
    """.utf8)
}

private func moreAppsParsedRelease(_ reading: Reading<ReleaseInfo>) -> ReleaseInfo? {
    if case let .ok(info, _, _) = reading { return info }
    return nil
}

@Suite("More apps release acceptance")
struct MoreAppsReleasesAcceptanceTests {
    @Test("release publication is retained as the exact date")
    func publishedAtParsesExactly() throws {
        let info = try #require(moreAppsParsedRelease(ReleaseParser.parse(moreAppsReleaseBody())))
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-10-20T09:30:00Z"))
        #expect(info.publishedAt == expected)
    }

    @Test("missing null and invalid publication dates do not reject a release")
    func invalidPublicationRemainsAnOKRelease() throws {
        for publication in ["", "null", "\"garbage\""] {
            let info = try #require(moreAppsParsedRelease(ReleaseParser.parse(
                moreAppsReleaseBody(publication: publication)
            )))
            #expect(info.tag == "v1.4.2")
            #expect(info.version == "1.4.2")
            #expect(info.publishedAt == nil)
        }
    }

    @Test("success uses the configured interval and keeps the daily default")
    func successUsesConfiguredInterval() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let success = start.addingTimeInterval(1_800)
        var sixHours = ReleaseCheckSchedule(now: start, interval: 6 * 3_600)
        sixHours.recordSuccess(at: success)
        #expect(sixHours.nextAutomatic == success.addingTimeInterval(6 * 3_600))
        var daily = ReleaseCheckSchedule(now: start)
        daily.recordSuccess(at: success)
        #expect(daily.nextAutomatic == success.addingTimeInterval(24 * 3_600))
    }

    @Test("repository endpoints allow only two safe ASCII components")
    func repositoryEndpointsValidateComponents() {
        #expect(GitHubReleases.endpoint(repo: "danieltamas/run.dev")?.absoluteString
            == "https://api.github.com/repos/danieltamas/run.dev/releases/latest")
        #expect(GitHubReleases.endpoint(repo: "Owner_1/App-2.3")?.absoluteString
            == "https://api.github.com/repos/Owner_1/App-2.3/releases/latest")
        let invalid = [
            "", "bton", "a/b/c", "/bton", "danieltamas/", "../x", "a/..", "./x", "a/.",
            "a b/c", "a/b?x=1", "a/b#x", "a/caf\u{00E9}", " a/b", "a/b\n", "a/b%2Fc"
        ]
        for repo in invalid {
            #expect(GitHubReleases.endpoint(repo: repo) == nil)
        }
    }

    @Test("HTTP 200 retains parsed release fields including publication")
    func successfulResponseReturnsRelease() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let answer = GitHubReleases.classify(status: 200, body: moreAppsReleaseBody(), retryAfter: nil, now: now)
        guard case let .release(info) = answer else {
            Issue.record("A valid final release must classify as release")
            return
        }
        let publication = try #require(ISO8601DateFormatter().date(from: "2026-10-20T09:30:00Z"))
        #expect(info == ReleaseInfo(
            tag: "v1.4.2", version: "1.4.2",
            htmlURL: "https://github.com/example/app/releases/tag/v1.4.2", publishedAt: publication
        ))
    }

    @Test("invalid HTTP 200 releases fail with a nonempty reason")
    func invalidSuccessfulResponsesFailClosed() {
        let bodies = [
            Data("not JSON".utf8), moreAppsReleaseBody(prerelease: true),
            moreAppsReleaseBody(tag: "nightly"), moreAppsReleaseBody(tag: "v1.2"), Data("{}".utf8)
        ]
        for body in bodies {
            let answer = GitHubReleases.classify(status: 200, body: body, retryAfter: nil)
            guard case let .failed(reason) = answer else {
                Issue.record("An invalid release must fail instead of reporting a release")
                continue
            }
            #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("HTTP 404 means no published release regardless of the body")
    func notFoundMeansNoRelease() {
        for body in [Data(), Data("not JSON".utf8), moreAppsReleaseBody()] {
            #expect(GitHubReleases.classify(status: 404, body: body, retryAfter: "120") == .none)
        }
    }

    @Test("HTTP 403 and 429 retain retry delays or unknown delays")
    func rateLimitedResponsesRetainDelay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for status in [403, 429] {
            #expect(GitHubReleases.classify(status: status, body: Data(), retryAfter: "120", now: now)
                == .rateLimited(retryAfter: 120))
            for header: String? in [nil, "", "soon"] {
                #expect(GitHubReleases.classify(status: status, body: moreAppsReleaseBody(), retryAfter: header, now: now)
                    == .rateLimited(retryAfter: nil))
            }
        }
    }

    @Test("other HTTP statuses fail with the specified reason")
    func otherStatusesFailWithStatusReason() {
        for status in [500, 302] {
            #expect(GitHubReleases.classify(status: status, body: moreAppsReleaseBody(), retryAfter: "120")
                == .failed(reason: "GitHub answered \(status)."))
        }
    }

    @Test("Retry-After accepts whole seconds and HTTP dates")
    func retryDelayParsesSecondsAndHTTPDate() throws {
        let deadline = try #require(ISO8601DateFormatter().date(from: "2026-10-21T07:28:00Z"))
        let now = deadline.addingTimeInterval(-90)
        #expect(GitHubReleases.retryDelay("120", now: now) == 120)
        #expect(GitHubReleases.retryDelay("  60 ", now: now) == 60)
        let delay = try #require(GitHubReleases.retryDelay("Wed, 21 Oct 2026 07:28:00 GMT", now: now))
        #expect(abs(delay - 90) < 1)
        for header: String? in [nil, "", "   ", "soon"] {
            #expect(GitHubReleases.retryDelay(header, now: now) == nil)
        }
    }

    @Test("absence takes precedence over all version inputs")
    func notInstalledTakesPrecedence() {
        let versions: [String?] = [nil, "1.2.0", "beta"]
        let tags: [String?] = [nil, "v1.4.2", "nightly"]
        for version in versions {
            for tag in tags {
                #expect(InstalledStanding.compare(isInstalled: false, installedVersion: version, latestTag: tag)
                    == .notInstalled)
            }
        }
    }

    @Test("installed versions compare numerically with normalized release versions")
    func installedVersionsCompareNumerically() {
        let cases: [(String, String, InstalledStanding)] = [
            ("1.2.0", "v1.4.2", .behind(latest: "1.4.2")),
            ("1.4.2", "v1.4.2", .current),
            ("1.9.0", "1.10.0", .behind(latest: "1.10.0")),
            ("2.0.0", "1.10.0", .ahead),
            ("  v1.4.2\n", " v1.4.2 ", .current),
            ("v1.2.0", " v1.04.2\n", .behind(latest: "1.4.2"))
        ]
        for (installed, latest, expected) in cases {
            #expect(InstalledStanding.compare(isInstalled: true, installedVersion: installed, latestTag: latest) == expected)
        }
    }

    @Test("missing or invalid installed and release versions remain unknown")
    func invalidInstalledVersionsRemainUnknown() {
        for version: String? in [nil, "1.2", "beta", "", "1.2.3.4"] {
            #expect(InstalledStanding.compare(isInstalled: true, installedVersion: version, latestTag: "v1.4.2") == .unknown)
        }
        for tag: String? in [nil, "nightly", "", "v1.4", "v1.4.2-beta"] {
            #expect(InstalledStanding.compare(isInstalled: true, installedVersion: "1.4.2", latestTag: tag) == .unknown)
        }
    }
}
