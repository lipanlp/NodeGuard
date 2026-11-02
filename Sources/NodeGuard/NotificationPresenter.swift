import Foundation
import UserNotifications

// macOS suppresses foreground presentation unless the application explicitly opts in.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    let foreground: @Sendable (String) -> Void
    let opened: @Sendable () -> Void
    init(foreground: @escaping @Sendable (String) -> Void, opened: @escaping @Sendable () -> Void) { self.foreground = foreground; self.opened = opened }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        foreground(notification.request.identifier)
        completionHandler([.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) { opened(); completionHandler() }
}
