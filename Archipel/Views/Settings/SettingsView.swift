import SwiftUI

/// The app-wide Settings window. Per-project options live in the project's own settings sheet.
struct SettingsView: View {
    enum Pane: String {
        case general, appearance, notifications, agents, worktrees, about
    }

    // HIG: reopen on the pane that was used last.
    @AppStorage(SettingsView.selectedPaneKey) private var pane: Pane = .general
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettingsView() }
            Tab("Appearance", systemImage: "paintbrush", value: .appearance) { AppearanceSettingsView() }
            Tab("Notifications", systemImage: "bell.badge", value: .notifications) { NotificationSettingsView() }
            Tab("Agents", systemImage: "sparkles", value: .agents) { AgentSettingsView() }
            Tab("Worktrees", systemImage: "arrow.triangle.branch", value: .worktrees) { WorktreeSettingsView() }
            Tab("About", systemImage: "info.circle", value: .about) { AboutSettingsView() }
        }
        // Sized to the selected tab, as system settings windows are, instead of scrolling a short form.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
        // Here and not on the main window, which may be closed while Settings is open.
        .onChange(of: model.settings.appearance) { model.applyAppearance() }
        .onChange(of: model.settings.showsDockBadge) { model.refreshDockBadge() }
    }

    private static let selectedPaneKey = "settings.selectedPane"

    /// Makes the Settings window show `pane`, whether it is opened next or open already: it reads
    /// its selection from the defaults.
    static func select(_ pane: Pane) {
        UserDefaults.standard.set(pane.rawValue, forKey: selectedPaneKey)
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
