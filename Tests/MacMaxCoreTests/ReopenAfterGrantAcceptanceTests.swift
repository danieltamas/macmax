import Foundation
import Testing
import MacMaxCore

@Suite("ReopenAfterGrantAcceptance")
struct ReopenAfterGrantAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The grant window is ten minutes")
    func window() {
        #expect(ReopenAfterGrant.window == 600)
    }

    @Test("Never pressing the access button never reopens", arguments: [false, true], [false, true])
    func neverPressed(quitByMacMax: Bool, endingSession: Bool) {
        #expect(!ReopenAfterGrant.shouldReopen(
            askedAt: nil, now: now, quitByMacMax: quitByMacMax, endingSession: endingSession
        ))
    }

    @Test("An outside quit within the window reopens", arguments: [1.0, 300.0, 599.0])
    func recentPress(elapsed: TimeInterval) {
        #expect(ReopenAfterGrant.shouldReopen(
            askedAt: now.addingTimeInterval(-elapsed), now: now,
            quitByMacMax: false, endingSession: false
        ))
    }

    @Test("The window excludes its endpoint and older presses", arguments: [600.0, 601.0, 7_200.0])
    func expiredPress(elapsed: TimeInterval) {
        #expect(!ReopenAfterGrant.shouldReopen(
            askedAt: now.addingTimeInterval(-elapsed), now: now,
            quitByMacMax: false, endingSession: false
        ))
    }

    @Test("MacMax Quit and Restart never trigger another reopen", arguments: [false, true])
    func ownQuit(endingSession: Bool) {
        #expect(!ReopenAfterGrant.shouldReopen(
            askedAt: now.addingTimeInterval(-1), now: now,
            quitByMacMax: true, endingSession: endingSession
        ))
    }

    @Test("Session ending always prevents reopening", arguments: [false, true])
    func sessionEnding(quitByMacMax: Bool) {
        #expect(!ReopenAfterGrant.shouldReopen(
            askedAt: now.addingTimeInterval(-1), now: now,
            quitByMacMax: quitByMacMax, endingSession: true
        ))
    }

    @Test("A future press fails closed", arguments: [1.0, 300.0, 7_200.0])
    func futurePress(offset: TimeInterval) {
        #expect(!ReopenAfterGrant.shouldReopen(
            askedAt: now.addingTimeInterval(offset), now: now,
            quitByMacMax: false, endingSession: false
        ))
    }

    @Test("Repeated decisions do not consume or change the press", arguments: [1.0, 599.0, 600.0, 7_200.0, -1.0])
    func pureDecision(elapsed: TimeInterval) {
        let askedAt = now.addingTimeInterval(-elapsed)
        let expected = elapsed == 1 || elapsed == 599
        for _ in 0..<5 {
            #expect(ReopenAfterGrant.shouldReopen(
                askedAt: askedAt, now: now, quitByMacMax: false, endingSession: false
            ) == expected)
        }
    }
}
