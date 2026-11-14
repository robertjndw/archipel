import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("System").tag(AppSettings.Appearance.system)
                    Text("Light").tag(AppSettings.Appearance.light)
                    Text("Dark").tag(AppSettings.Appearance.dark)
                }
                .pickerStyle(.inline)
            } footer: {
                Text("System follows the appearance chosen in System Settings.")
            }

            Section {
                Toggle("Show git status", isOn: $settings.showsGitStatusInSidebar)
                Toggle("Show pull requests", isOn: $settings.showsPullRequests)
                Toggle("Show agent messages", isOn: $settings.showsAgentMessagesInSidebar)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Git status shows changed files and ahead or behind counts next to each worktree. Pull requests are looked up with the gh command line tool, which must be installed and signed in. Agent messages show the latest thing each session said.")
            }
        }
        .formStyle(.grouped)
    }
}
