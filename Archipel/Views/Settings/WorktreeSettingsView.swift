import AppKit
import SwiftUI

struct WorktreeSettingsView: View {
    private enum EditorChoice: Hashable {
        case automatic
        case editor(String)
        case other
    }

    @Environment(AppModel.self) private var model
    @State private var isChoosingFolder = false
    /// Why the application picked with Other… was refused, until a choice that works is made.
    @State private var editorProblem: String?

    var body: some View {
        @Bindable var settings = model.settings
        let installed = model.installedEditors
        Form {
            Section {
                WorktreesFolderPicker(isChoosingFolder: $isChoosingFolder)

                TextField(text: $settings.branchPrefix, prompt: Text("yourname/")) {
                    Text("Branch prefix")
                    Text("Added in front of new branch names, unless the name you type already contains a slash.")
                    if !AppModel.isValidBranchPrefix(settings.branchPrefix) {
                        Text("Not a valid branch prefix, so it is not used. Avoid spaces and ~ ^ : ? * [ \\, and don't start with a dash.")
                            .foregroundStyle(.red)
                    }
                }
                .autocorrectionDisabled()

                Toggle(isOn: $settings.fetchesAutomatically) {
                    Text("Fetch automatically")
                    Text("Keeps behind counts current while Archipel is in front. Only remote branches are updated.")
                }
            }

            Section {
                Picker(selection: Binding<EditorChoice>(
                    get: { settings.externalEditorBundleID.map(EditorChoice.editor) ?? .automatic },
                    set: { choice in
                        switch choice {
                        case .automatic:
                            settings.externalEditorBundleID = nil
                            editorProblem = nil
                        case .editor(let id):
                            settings.externalEditorBundleID = id
                            editorProblem = nil
                        case .other:
                            model.chooseOtherEditor { editorProblem = $0 }
                        }
                    }
                )) {
                    if let first = installed.first(where: \.isKnown) {
                        Label { Text("Automatic (\(first.name))") } icon: { Image(nsImage: .menuIcon(forFile: first.url.path)) }
                            .tag(EditorChoice.automatic)
                        Divider()
                    } else {
                        Text("Automatic (None Installed)").tag(EditorChoice.automatic)
                    }
                    ForEach(installed) { editor in
                        Label { Text(editor.name) } icon: { Image(nsImage: .menuIcon(forFile: editor.url.path)) }
                            .tag(EditorChoice.editor(editor.bundleID))
                    }
                    // A choice whose app was removed still has to show up, or the control looks empty.
                    if let id = settings.externalEditorBundleID, !installed.contains(where: { $0.bundleID == id }) {
                        Text("\(ExternalEditor.name(forBundleID: id)) (Not Installed)").tag(EditorChoice.editor(id))
                    }
                    Divider()
                    Text("Other…").tag(EditorChoice.other)
                } label: {
                    Text("Open in editor")
                    Text(installed.isEmpty
                        ? "Install an editor such as Visual Studio Code, Cursor or Zed, or pick another application."
                        : "Used by Open in Editor (⇧⌘E) and the context menus.")
                    if let editorProblem {
                        Text(editorProblem)
                            .foregroundStyle(.red)
                    }
                }
            }
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
#Preview("Worktrees") {
    WorktreeSettingsView()
        .environment(AppModel.preview())
        // The size the Settings window gives each pane.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("Custom folder and branch prefix") {
    let model = AppModel.preview()
    model.settings.worktreesRoot = PreviewFixtures.root.appending(path: "worktrees", directoryHint: .isDirectory)
    model.settings.branchPrefix = "alex/"
    model.settings.fetchesAutomatically = false
    return WorktreeSettingsView()
        .environment(model)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}
#endif
