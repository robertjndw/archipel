import SwiftUI

/// The app-wide Settings window. Per-project options live in the project's own settings sheet.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettingsView() }
            Tab("Appearance", systemImage: "paintbrush") { AppearanceSettingsView() }
            Tab("Notifications", systemImage: "bell.badge") { NotificationSettingsView() }
            Tab("Agents", systemImage: "sparkles") { AgentSettingsView() }
        }
        // Sized to the selected tab, as system settings windows are, instead of scrolling a short form.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 520)
    }
}
