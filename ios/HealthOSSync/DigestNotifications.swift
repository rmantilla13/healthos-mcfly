import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when the weekly digest notification is tapped, so the app opens Insights (under More).
    static let openWeeklyDigest = Notification.Name("openWeeklyDigest")
}

/// A local reminder every Monday at 09:00 that last week's digest is ready. The phone schedules it on its own;
/// McFly writes the digest when Insights opens, so nothing health-related is in the notification.
enum DigestNotifications {
    static let id = "weekly-digest"
    private static let key = "digestNotification"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Asks for permission, then schedules the weekly reminder. False (and off) when notifications aren't allowed.
    @discardableResult
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        // A throw means iOS couldn't ask; treat it like a no.
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            enabled = false
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = "Your weekly digest is ready"
        content.body = "See how last week went in healthOS."
        content.sound = .default
        // Weekday 2 is Monday (1 is Sunday).
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 9, minute: 0, weekday: 2), repeats: true)
        do {
            // Same identifier, so turning it on again replaces the request instead of adding a second one.
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            enabled = false
            return false
        }
        enabled = true
        return true
    }

    static func disable() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
        enabled = false
    }

    /// Notifications were turned off for the app in iOS Settings.
    static func denied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    // A tap can launch the app before any screen exists to switch tabs, so it's kept until RootView takes it.
    @MainActor private static var openRequested = false

    @MainActor static func requestOpen() {
        openRequested = true
        NotificationCenter.default.post(name: .openWeeklyDigest, object: nil)
    }

    /// True once per tap.
    @MainActor static func takeOpenRequest() -> Bool {
        defer { openRequested = false }
        return openRequested
    }
}
