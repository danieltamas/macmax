import AppKit
import MacMaxCore
import os

/// The Full Disk Access buttons, and the reopen that System Settings promises after the grant but does not always
/// do for a menu bar app (ReopenAfterGrant).
@MainActor
enum FullDiskAccessGrant {
    private static var askedAt: Date?
    private static var quitByMacMax = false
    private static var endingSession = false
    private static var observers: [NSObjectProtocol] = []
    private static let log = Logger(subsystem: "ro.danieltamas.macmax", category: "reopen")

    static func openSettings() {
        askedAt = Date()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Every quit MacMax makes itself (Quit, Restart, Cmd-Q) says so first. System Settings' quit carries nothing
    /// MacMax can read by the time it terminates (no current Apple event), so the flag is what tells the two apart.
    static func quit() {
        quitByMacMax = true
        NSApp.terminate(nil)
    }

    static func watch() {
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { endingSession = true }
        })
        // An update's installer stops MacMax with a signal, which never reaches here: only an AppKit quit does.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { reopenIfGranting() }
        })
    }

    private static func reopenIfGranting() {
        let reopen = ReopenAfterGrant.shouldReopen(askedAt: askedAt, now: Date(), quitByMacMax: quitByMacMax,
                                                   endingSession: endingSession)
        log.info("quit by MacMax \(quitByMacMax, privacy: .public), reopen \(reopen, privacy: .public)")
        // If System Settings reopens MacMax as well, the helper's `open` finds it running and only brings it forward.
        if reopen { _ = NSApp.openAgainWhenGone() }
    }
}
