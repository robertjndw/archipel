import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var stayAwake = model.stayAwake
        Form {
            Section {
                Picker(selection: $settings.fileLinkDestination) {
                    Text("Archipel").tag(AppSettings.LinkDestination.archipel)
                    Text("Default App").tag(AppSettings.LinkDestination.defaultApp)
                } label: {
                    Text("Open files in")
                    Text("Text files, images and PDFs open in a tab. Folders always open in Finder.")
                }

                Picker(selection: $settings.webLinkDestination) {
                    Text("Archipel").tag(AppSettings.LinkDestination.archipel)
                    Text("Default Browser").tag(AppSettings.LinkDestination.defaultApp)
                } label: {
                    Text("Open web links in")
                    Text("Also used by the dev server button on a session's tab.")
                }
            } header: {
                Text("Terminal Links")
            } footer: {
                Text("⌘-click a link in a terminal to open it. ⌘⌥-click uses the other choice.")
            }

            Section {
                Picker(selection: $stayAwake.mode) {
                    ForEach(StayAwake.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Keep Mac awake")
                    Text("Stops the Mac from idle sleeping so agents can finish long turns.")
                }

                Toggle(isOn: $stayAwake.keepsDisplayAwake) {
                    Text("Keep display awake")
                    Text("Otherwise the display may turn off while the Mac stays awake. Closing the lid still puts the Mac to sleep.")
                }
                .disabled(stayAwake.mode == .off)
            } header: {
                Text("Stay Awake")
            }

            Section {
                Toggle(isOn: $settings.showsMenuBarExtra) {
                    Text("Show in menu bar")
                    Text("Shows when agents are working or waiting, and jumps to them.")
                }
                Toggle(isOn: $settings.confirmsQuitWhileWorking) {
                    Text("Ask before quitting while agents are working")
                    Text("Quitting stops agents. Their conversations resume when you reopen the session.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
#Preview("General") {
    GeneralSettingsView()
        .environment(AppModel.preview())
        // The size the Settings window gives each pane.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("Links to default apps, menu bar off") {
    let model = AppModel.preview()
    model.settings.fileLinkDestination = .defaultApp
    model.settings.webLinkDestination = .defaultApp
    model.settings.showsMenuBarExtra = false
    return GeneralSettingsView()
        .environment(model)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}
#endif
