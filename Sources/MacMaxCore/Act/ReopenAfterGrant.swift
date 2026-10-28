import Foundation

/// System Settings quits MacMax once its Full Disk Access switch is turned on and offers to reopen it, but it never
/// reopens a menu bar app. A quit from outside shortly after the user pressed MacMax's own Full Disk Access button is
/// taken as that quit, and MacMax opens itself again.
public enum ReopenAfterGrant {
    /// How long after the press a quit from outside still counts as System Settings applying the grant.
    public static let window: TimeInterval = 600

    public static func shouldReopen(askedAt: Date?, now: Date, quitByMacMax: Bool, endingSession: Bool) -> Bool {
        // Reopening during a logout or shutdown would hold it up; Quit means closed, and Restart reopens by itself.
        guard let askedAt, !quitByMacMax, !endingSession else { return false }
        let elapsed = now.timeIntervalSince(askedAt)
        // A press "in the future" means the clock moved: the elapsed time is unknown, so no reopen.
        return elapsed >= 0 && elapsed < window
    }
}
