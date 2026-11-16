import AgentKit
import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @State private var isChoosingFolder = false

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var stayAwake = model.stayAwake
        @Bindable var updater = updater
        let installed = ExternalEditor.installed()
        Form {
            Section {
                Picker(selection: $settings.defaultAgentID) {
                    ForEach(AgentDefinition.builtIns) { agent in
                        Label(agent.displayName, symbol: agent.symbolName).tag(agent.id)
                    }
                } label: {
                    Text("Default agent")
                    Text("Started by New Session (⌘T) and the plus button.")
                }

                Picker(selection: $settings.externalEditorBundleID) {
                    if let first = installed.first {
                        Label { Text("Automatic (\(first.name))") } icon: { Image(nsImage: .menuIcon(forFile: first.url.path)) }
                            .tag(String?.none)
                        Divider()
                    } else {
                        Text("None Installed").tag(String?.none)
                    }
                    ForEach(installed) { editor in
                        Label { Text(editor.name) } icon: { Image(nsImage: .menuIcon(forFile: editor.url.path)) }
                            .tag(Optional(editor.bundleID))
                    }
                } label: {
                    Text("Open in editor")
                    Text(installed.isEmpty
                        ? "Install an editor such as Visual Studio Code, Cursor or Zed to open worktrees from Archipel."
                        : "Used by Open in Editor (⇧⌘E) and the context menus.")
                }
                .disabled(installed.isEmpty)
            }

            Section("Worktrees") {
                WorktreesFolderPicker(isChoosingFolder: $isChoosingFolder)

                TextField(text: $settings.branchPrefix, prompt: Text("yourname/")) {
                    Text("Branch prefix")
                    Text("Filled in for new branches and still editable each time.")
                }
                .autocorrectionDisabled()

                Toggle(isOn: $settings.fetchesAutomatically) {
                    Text("Fetch automatically")
                    Text("Keeps behind counts current while Archipel is in front. Only remote branches are updated.")
                }
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

            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Toggle(isOn: $updater.receivesBetaUpdates) {
                    Text("Include beta versions")
                    Text("Betas arrive earlier and may be rough around the edges. When a stable version is newer than your beta, you get that one.")
                }
                HStack {
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            } footer: {
                if !Updater.isEnabled {
                    Text("Updates are turned off in debug builds.")
                }
            }
            .disabled(!Updater.isEnabled)
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { settings.worktreesRoot = url }
        }
    }
}

/// A folder pop-up like Safari's download location: the current folder, the default to go back to,
/// and Other… to pick a new one.
private struct WorktreesFolderPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var isChoosingFolder: Bool

    private enum Choice: Hashable {
        case folder(URL)
        case other
    }

    var body: some View {
        let settings = model.settings
        let current = settings.worktreesRoot.standardizedFileURL
        let standard = AppSettings.standardWorktreesRoot.standardizedFileURL
        Picker(selection: Binding<Choice>(
            get: { .folder(current) },
            set: { choice in
                switch choice {
                case .folder(let url): settings.worktreesRoot = url
                case .other: isChoosingFolder = true
                }
            }
        )) {
            folderLabel(current, isStandard: current == standard).tag(Choice.folder(current))
            if current != standard {
                folderLabel(standard, isStandard: true).tag(Choice.folder(standard))
            }
            Divider()
            Text("Other…").tag(Choice.other)
        } label: {
            Text("Location")
            Text("\(current.abbreviatedPath)/‹project›/‹branch›")
        }
    }

    private func folderLabel(_ url: URL, isStandard: Bool) -> some View {
        Label {
            Text(isStandard ? "\(url.lastPathComponent) (Default)" : url.lastPathComponent)
        } icon: {
            Image(nsImage: .menuIcon(forFile: url.path))
        }
    }
}

#if DEBUG
#Preview("General") {
    GeneralSettingsView()
        .environment(AppModel.preview())
        .environment(Updater())
        // The size the Settings window gives each pane.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("Custom folder and branch prefix") {
    let model = AppModel.preview()
    model.settings.defaultAgentID = "codex"
    model.settings.worktreesRoot = PreviewFixtures.root.appending(path: "worktrees", directoryHint: .isDirectory)
    model.settings.branchPrefix = "alex/"
    model.settings.fetchesAutomatically = false
    model.settings.showsMenuBarExtra = false
    return GeneralSettingsView()
        .environment(model)
        .environment(Updater())
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}
#endif
