import AppKit
import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("When an agent needs you", isOn: $settings.notifiesWhenAttentionNeeded)
                Toggle("When an agent finishes a turn", isOn: $settings.notifiesWhenFinished)
                Toggle("When a session exits", isOn: $settings.notifiesWhenExited)
            } header: {
                Text("Notify")
            } footer: {
                Text("Only sessions you are not looking at notify you. Clicking a notification opens its session.")
            }

            Section {
                Toggle("Play sound", isOn: $settings.playsNotificationSound)
                Toggle("Show count on Dock icon", isOn: $settings.showsDockBadge)
                Toggle("Not while Archipel is the active app", isOn: $settings.suppressesNotificationsWhileActive)
            } footer: {
                Text("The Dock count is the number of sessions waiting for you. With the last option on, you still see the island markers and the Dock count, but no banners.")
            }

            Section {
                if let note = authorizationNote {
                    Text(note).foregroundStyle(.secondary)
                }
                Button("Open Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Banners, alerts and sounds can also be turned off for all of Archipel in System Settings.")
            }
        }
        .formStyle(.grouped)
        .task { await refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorization() }
        }
    }

    private var authorizationNote: String? {
        switch authorization {
        case .denied: "Notifications are turned off for Archipel in System Settings, so none of the options above will show a banner."
        case .notDetermined: "macOS has not asked yet whether Archipel may send notifications."
        default: nil
        }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
