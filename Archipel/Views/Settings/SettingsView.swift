import SwiftUI

/// The app-wide Settings window. Per-project options live in the project's own settings sheet.
struct SettingsView: View {
    enum Pane: String {
        case general, appearance, notifications, agents
    }

    // HIG: reopen on the pane that was used last.
    @AppStorage("settings.selectedPane") private var pane: Pane = .general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettingsView() }
            Tab("Appearance", systemImage: "paintbrush", value: .appearance) { AppearanceSettingsView() }
            Tab("Notifications", systemImage: "bell.badge", value: .notifications) { NotificationSettingsView() }
            Tab("Agents", systemImage: "sparkles", value: .agents) { AgentSettingsView() }
        }
        // Sized to the selected tab, as system settings windows are, instead of scrolling a short form.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
    }
}

#if DEBUG
#Preview("Window") {
    SettingsView()
        .environment(AppModel.preview())
        .environment(Updater())
}

#Preview("Window, dark") {
    SettingsView()
        .environment(AppModel.preview())
        .environment(Updater())
        .preferredColorScheme(.dark)
}
#endif
