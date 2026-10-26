import UserNotifications

/// What the user has told macOS about MacMax's notifications.
enum NotificationAccess: Equatable {
    case allowed, denied, notAsked
    /// macOS could not be asked: no bundle (a build folder run), or the settings did not come back.
    case unknown
}

enum SystemNotifications {
    /// Only an installed, bundled app has a notification center; asking from a bare binary would trap.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func current() async -> NotificationAccess {
        guard available else { return .unknown }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return access(settings.authorizationStatus)
    }

    /// Shows macOS's own permission dialog the first time; afterwards it only reads the answer.
    static func request() async -> NotificationAccess {
        guard available else { return .unknown }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await current()
    }

    /// A plain notification; nothing happens when the person has not allowed them.
    static func post(title: String, body: String) async {
        guard await current() == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        _ = try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func access(_ status: UNAuthorizationStatus) -> NotificationAccess {
        switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .unknown
        }
    }
}
