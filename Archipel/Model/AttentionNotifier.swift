import AppKit
import ArchipelCore
import UserNotifications

/// System notifications and the Dock badge: the two signals that still reach
/// the user when Archipel is in the background.
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpenSession: ((Session.ID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private nonisolated static let sessionKey = "sessionID"
    private var dockBadgeCount = 0

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(sessionID: Session.ID, title: String, subtitle: String, body: String?, playsSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        if let body { content.body = body }
        if playsSound { content.sound = .default }
        content.userInfo = [Self.sessionKey: sessionID.uuidString]
        // One notification per session: a newer state replaces the older one
        // instead of stacking up in Notification Center.
        let request = UNNotificationRequest(identifier: sessionID.uuidString, content: content, trigger: nil)
        center.add(request)
    }

    func clear(sessionID: Session.ID) {
        center.removeDeliveredNotifications(withIdentifiers: [sessionID.uuidString])
    }

    /// Called on every hook event, and each badge update is a round trip to the Dock.
    func setDockBadge(_ count: Int) {
        guard count != dockBadgeCount else { return }
        dockBadgeCount = count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo[Self.sessionKey] as? String
        guard let raw, let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            NSApp.activate()
            onOpenSession?(id)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
