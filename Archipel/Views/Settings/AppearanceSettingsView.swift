import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Appearance") {
                    TilePicker(
                        selection: $settings.appearance,
                        options: AppSettings.Appearance.allCases,
                        title: \.title
                    ) { appearance in
                        AppearancePreview(appearance: appearance)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Sidebar") {
                Toggle(isOn: $settings.showsGitStatusInSidebar) {
                    Text("Git status")
                    Text("Changed files and ahead or behind counts next to each worktree.")
                }
                Toggle(isOn: $settings.showsPullRequests) {
                    Text("Pull requests")
                    Text("Looked up with the gh command line tool, which must be installed and signed in.")
                }
                Toggle(isOn: $settings.showsAgentMessagesInSidebar) {
                    Text("Agent messages")
                    Text("The latest thing each session said.")
                }
            }

            Section {
                LabeledContent {
                    TilePicker(
                        selection: $settings.usageDisplay,
                        options: AppSettings.UsageDisplay.allCases,
                        title: \.title
                    ) { display in
                        UsageDisplayPreview(display: display, fill: settings.usageBarFill)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Text("Usage limits")
                    Text("Claude and Codex subscription limits. Click them in the status bar for details.")
                }
                if settings.usageDisplay == .bars {
                    // fixedSize only on the control. On the whole picker the form can't stretch the
                    // row and the control ends short of the trailing edge.
                    LabeledContent {
                        Picker("Bars show", selection: $settings.usageBarFill) {
                            ForEach(AppSettings.UsageBarFill.allCases) { fill in
                                Text(fill.title).tag(fill)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    } label: {
                        Text("Bars show")
                        Text(settings.usageBarFill == .used
                            ? "Bars fill up as you work."
                            : "Bars empty like a battery as you work.")
                    }
                }
            } header: {
                Text("Status Bar")
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.usageDisplay)
    }
}

extension AppSettings.Appearance {
    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
