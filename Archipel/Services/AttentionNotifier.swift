import AppKit
import ArchipelCore
import UserNotifications

/// System notifications and the Dock badge: the two signals that still reach
/// the user when Archipel is in the background.
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// The buttons a notification offers. Every action runs in the background: answering an
    /// agent from a banner should not pull the user away from what they are doing.
    enum Category: String, CaseIterable {
        case permission = "archipel.permission"
        case reply = "archipel.reply"
    }

    /// What the user chose on a notification, with what is needed to check it still applies.
    struct Response {
        enum Choice {
            case allow
            case deny
            case reply(String)
        }

        var sessionID: Session.ID
        var choice: Choice
        /// The state the notification was about, as `AttentionNotifier.statusKey(_:)` encodes it.
        var status: String
        var token: String
    }

    var onOpenSession: ((Session.ID) -> Void)?
    var onResponse: ((Response) -> Void)?
    /// Sessions whose banners were held back while the user was sharing their screen.
    var held = HeldNotifications()
    var holdWatch: Task<Void, Never>?

    private let center = UNUserNotificationCenter.current()
    private nonisolated static let sessionKey = "sessionID"
    private nonisolated static let statusKey = "status"
    private nonisolated static let tokenKey = "token"
    private nonisolated static let summaryIdentifier = "archipel.summary"
    private var dockBadgeCount = 0
    /// The token of each session's newest notification. Anything else, or anything posted before the
    /// session's state last changed, is stale and must not be answered on the agent's behalf.
    private var tokens: [Session.ID: String] = [:]
    /// Sessions that may still have a banner in Notification Center. `clear` runs on every selection
    /// change, and without this each of those would be a round trip to the notification daemon.
    private var delivered: Set<Session.ID> = []
    private var hasRequestedAuthorization = false

    func start() {
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        // Banners of the previous run are still there, and looking at their session has to clear them too.
        center.getDeliveredNotifications { [weak self] notifications in
            let ids = notifications.compactMap { UUID(uuidString: $0.request.identifier) }
            Task { @MainActor in self?.delivered.formUnion(ids) }
        }
    }

    /// Asked when the first agent starts rather than at launch: by then the user has done something
    /// that explains why Archipel wants to notify them. The system only ever shows the dialog once.
    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static var categories: Set<UNNotificationCategory> {
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny", options: [])
        let reply = UNTextInputNotificationAction(
            identifier: Action.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message to the agent"
        )
        return [
            UNNotificationCategory(identifier: Category.permission.rawValue, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.reply.rawValue, actions: [reply], intentIdentifiers: []),
        ]
    }

    private enum Action {
        static let allow = "archipel.allow"
        static let deny = "archipel.deny"
        static let reply = "archipel.reply"
    }

    static func statusKey(_ status: SessionStatus) -> String {
        switch status {
        case .notStarted: "notStarted"
        case .starting: "starting"
        case .working: "working"
        case .needsAttention(let reason): "needsAttention.\(reason.rawValue)"
        case .finished: "finished"
        case .exited(let code): "exited.\(code)"
        }
    }

    func post(
        sessionID: Session.ID,
        title: String,
        subtitle: String,
        body: String?,
        playsSound: Bool,
        status: SessionStatus,
        category: Category?
    ) {
        let token = UUID().uuidString
        tokens[sessionID] = token
        delivered.insert(sessionID)
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        if let body { content.body = body }
        if playsSound { content.sound = .default }
        if let category { content.categoryIdentifier = category.rawValue }
        content.userInfo = [
            Self.sessionKey: sessionID.uuidString,
            Self.statusKey: Self.statusKey(status),
            Self.tokenKey: token,
        ]
        // One notification per session: a newer state replaces the older one
        // instead of stacking up in Notification Center.
        let request = UNNotificationRequest(identifier: sessionID.uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// The one notification that stands in for everything held back while the user was busy.
    /// Tapping it opens `sessionID`.
    func postSummary(title: String, body: String, sessionID: Session.ID, playsSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if playsSound { content.sound = .default }
        content.userInfo = [Self.sessionKey: sessionID.uuidString]
        center.add(UNNotificationRequest(identifier: Self.summaryIdentifier, content: content, trigger: nil))
    }

    func clear(sessionID: Session.ID) {
        tokens[sessionID] = nil
        guard delivered.remove(sessionID) != nil else { return }
        center.removeDeliveredNotifications(withIdentifiers: [sessionID.uuidString])
    }

    /// Keeps the notification on screen but stops its buttons from acting: what it asked about is over.
    func invalidate(sessionID: Session.ID) {
        tokens[sessionID] = nil
    }

    func isCurrent(_ response: Response) -> Bool {
        tokens[response.sessionID] == response.token
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
        let info = response.notification.request.content.userInfo
        guard let raw = info[Self.sessionKey] as? String, let id = UUID(uuidString: raw) else { return }

        let choice: Response.Choice?
        switch response.actionIdentifier {
        case Action.allow: choice = .allow
        case Action.deny: choice = .deny
        case Action.reply: choice = (response as? UNTextInputNotificationResponse).map { .reply($0.userText) }
        case UNNotificationDefaultActionIdentifier: choice = nil
        default: return
        }
        let status = info[Self.statusKey] as? String ?? ""
        let token = info[Self.tokenKey] as? String ?? ""
        await MainActor.run {
            if let choice {
                onResponse?(Response(sessionID: id, choice: choice, status: status, token: token))
            } else {
                // The receiver brings the app and its window forward; see AppModel.showMainWindow().
                onOpenSession?(id)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
