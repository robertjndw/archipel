import AppKit
import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        @Bindable var settings = model.settings
        let notifiesAtAll = settings.notifiesWhenAttentionNeeded || settings.notifiesWhenFinished || settings.notifiesWhenExited
        Form {
            if let note = authorizationNote {
                Section {
                    LabeledContent {
                        Button("Open System Settings…", action: openSystemSettings)
                    } label: {
                        Label {
                            Text(note.title)
                            Text(note.detail)
                        } icon: {
                            Image(systemName: "bell.slash.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section {
                Toggle(isOn: $settings.notifiesWhenAttentionNeeded) {
                    Text("An agent needs you")
                    Text("Allow, Deny or Reply right from the notification.")
                }
                Toggle("An agent finishes a turn", isOn: $settings.notifiesWhenFinished)
                Toggle("A session exits", isOn: $settings.notifiesWhenExited)
            } header: {
                Text("Notify Me When")
            } footer: {
                Text("Only for sessions you are not looking at. Click a notification to open its session.")
            }

            Section {
                Toggle("Play sound", isOn: $settings.playsNotificationSound)
                Toggle(isOn: $settings.suppressesNotificationsWhileActive) {
                    Text("Hold back while Archipel is in front")
                    Text("You still see island markers and the Dock count.")
                }
                Toggle(isOn: $settings.holdsNotificationsWhileSharingScreen) {
                    Text("Hold back while sharing your screen")
                    Text("Delivered as one summary afterwards. Covers mirroring, Screen Sharing and Zoom, not browser sharing.")
                }
            }
            .disabled(!notifiesAtAll)

            Section {
                Toggle(isOn: $settings.showsDockBadge) {
                    Text("Show count on Dock icon")
                    Text("The number of sessions waiting for you.")
                }
            }

            if authorizationNote == nil {
                Section {
                    LabeledContent("Banner style, Focus and more are set in System Settings.") {
                        Button("Open System Settings…", action: openSystemSettings)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorization() }
        }
    }

    private var authorizationNote: (title: String, detail: String)? {
        switch authorization {
        case .denied: ("Notifications are off", "Turned off for Archipel in System Settings, so nothing below shows a banner.")
        case .notDetermined: ("Not allowed yet", "macOS has not asked yet whether Archipel may send notifications.")
        default: nil
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

#if DEBUG
#Preview("Notifications") {
    NotificationSettingsView()
        .environment(AppModel.preview())
        // The size the Settings window gives each pane.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("All notifications off") {
    let model = AppModel.preview()
    model.settings.notifiesWhenAttentionNeeded = false
    model.settings.notifiesWhenFinished = false
    model.settings.notifiesWhenExited = false
    return NotificationSettingsView()
        .environment(model)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}
#endif
