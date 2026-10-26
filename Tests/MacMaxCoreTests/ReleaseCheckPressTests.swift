import Foundation
import Testing
@testable import MacMaxCore

struct ReleaseCheckPressTests {
    @Test func aPressSkipsTheFloorButNotGitHubsPause() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var schedule = ReleaseCheckSchedule(now: start)
        schedule.recordSuccess(at: start)
        #expect(!schedule.mayCheck(at: start.addingTimeInterval(60)))
        #expect(schedule.mayCheckByPress(at: start.addingTimeInterval(60)))
        schedule.recordRateLimit(at: start, retryAfter: 3_600)
        #expect(!schedule.mayCheckByPress(at: start.addingTimeInterval(3_599)))
        #expect(schedule.mayCheckByPress(at: start.addingTimeInterval(3_600)))
    }
}
