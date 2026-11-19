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
                LabeledContent {
                    TilePicker(
                        selection: $settings.paneStyle,
                        options: AppSettings.PaneStyle.allCases,
                        title: \.title
                    ) { style in
                        PaneStylePreview(style: style)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Text("Panes")
                    Text(settings.paneStyle.summary)
                }
            }

            Section("Sidebar") {
                LabeledContent {
                    TilePicker(
                        selection: $settings.sidebarDensity,
                        options: AppSettings.SidebarDensity.allCases,
                        title: \.title
                    ) { density in
                        SidebarDensityPreview(density: density)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Text("Density")
                    Text(settings.sidebarDensity.summary)
                }
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

            Section("Status Bar") {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBarPreview(settings: settings)
                    Text("Right-click the status bar, or this preview, to choose what it shows.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                // The context ring follows the usage style, so the style stays while either shows.
                if settings.shows(.usage) || settings.shows(.context) {
                    usageStyle(settings)
                }
            }
        }
        .formStyle(.grouped)
        .animation(Motion.disclosure, value: settings.usageDisplay)
        .animation(Motion.disclosure, value: settings.hiddenStatusBarItems)
    }

    @ViewBuilder private func usageStyle(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings
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
            Text("Style")
            Text("How usage limits and the context ring are drawn.")
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
                    ? "Bars and the ring fill up as you work."
                    : "Bars and the ring empty like a battery as you work.")
            }
        }
    }
}

extension AppSettings.SidebarDensity {
    var summary: String {
        switch self {
        case .compact: "One line per worktree. Agent messages show on hover."
        case .comfortable: "Two lines per worktree: the branch, then what needs you or its changes."
        case .spacious: "More room around projects, and two lines for a waiting agent's question."
        }
    }
}

extension AppSettings.PaneStyle {
    var summary: String {
        switch self {
        case .compact: "Split panes sit edge to edge with a thin line between them."
        case .comfortable: "Split panes get rounded corners and a little room around them."
        }
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

#if DEBUG
#Preview("Appearance") {
    AppearanceSettingsView()
        .environment(AppModel.preview())
        // The size the Settings window gives each pane.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("Usage bars, remaining") {
    let model = AppModel.preview()
    model.settings.usageDisplay = .bars
    model.settings.usageBarFill = .remaining
    return AppearanceSettingsView()
        .environment(model)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("Status bar, some items off") {
    let model = AppModel.preview()
    model.settings.hiddenStatusBarItems = [.usage, .resources]
    return AppearanceSettingsView()
        .environment(model)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("Compact, sidebar extras off") {
    let model = AppModel.preview()
    model.settings.sidebarDensity = .compact
    model.settings.showsGitStatusInSidebar = false
    model.settings.showsPullRequests = false
    model.settings.showsAgentMessagesInSidebar = false
    return AppearanceSettingsView()
        .environment(model)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}
#endif
