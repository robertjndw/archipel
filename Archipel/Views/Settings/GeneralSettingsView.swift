import AgentKit
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isChoosingFolder = false

    var body: some View {
        @Bindable var settings = model.settings
        let installed = ExternalEditor.installed()
        Form {
            Section {
                Picker("Default agent", selection: $settings.defaultAgentID) {
                    ForEach(AgentDefinition.builtIns) { agent in
                        Label(agent.displayName, systemImage: agent.symbolName).tag(agent.id)
                    }
                }
            } footer: {
                Text("Started by New Session (⌘T) and the plus button. The other agents stay in the File menu.")
            }

            Section {
                LabeledContent("Folder") {
                    Text(settings.worktreesRoot.abbreviatedPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Reset") { settings.worktreesRoot = AppSettings.standardWorktreesRoot }
                        .disabled(settings.worktreesRoot.standardizedFileURL == AppSettings.standardWorktreesRoot.standardizedFileURL)
                    Button("Choose…") { isChoosingFolder = true }
                }
            } header: {
                Text("Worktrees")
            } footer: {
                Text("New worktrees are created in <folder>/<project>/<branch>. A project can use a folder of its own in its project settings. Existing worktrees stay where they are.")
            }

            Section {
                TextField("Branch prefix", text: $settings.branchPrefix, prompt: Text("robert/"))
                    .autocorrectionDisabled()
            } footer: {
                Text("Filled in when you create a new branch, for example robert/ gives robert/fix-login. You can still edit it per branch.")
            }

            Section {
                Picker("Open in", selection: $settings.externalEditorBundleID) {
                    Text(installed.first.map { "Automatic (\($0.name))" } ?? "Automatic").tag(String?.none)
                    if !installed.isEmpty { Divider() }
                    ForEach(installed) { editor in
                        Text(editor.name).tag(Optional(editor.bundleID))
                    }
                }
            } header: {
                Text("Editor")
            } footer: {
                Text(installed.isEmpty
                    ? "No supported editor was found. Install one such as Visual Studio Code, Cursor or Zed to open worktrees from Archipel."
                    : "Used by Open in Editor (⇧⌘E) and the context menus of worktrees, projects and files.")
            }

            Section {
                Toggle("Fetch from remotes automatically", isOn: $settings.fetchesAutomatically)
            } footer: {
                Text("Runs git fetch every few minutes while Archipel is in front, so the behind counts stay current. It only updates remote branches, never your own branches or files.")
            }

            Section {
                Toggle("Show in menu bar", isOn: $settings.showsMenuBarExtra)
            } footer: {
                Text("A small icon that shows when agents are working or waiting for you, and jumps to them.")
            }

            Section {
                Toggle("Confirm before quitting while agents are working", isOn: $settings.confirmsQuitWhileWorking)
            } footer: {
                Text("Quitting stops running agents. Their conversations are kept and resume the next time you open the session.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { settings.worktreesRoot = url }
        }
    }
}
