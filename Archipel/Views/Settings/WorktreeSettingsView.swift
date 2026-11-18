import AppKit
import SwiftUI

struct WorktreeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isChoosingFolder = false

    var body: some View {
        @Bindable var settings = model.settings
        let installed = model.installedEditors
        Form {
            Section {
                WorktreesFolderPicker(isChoosingFolder: $isChoosingFolder)

                TextField(text: $settings.branchPrefix, prompt: Text("yourname/")) {
                    Text("Branch prefix")
                    Text("Added in front of new branch names, unless the name you type already contains a slash.")
                }
                .autocorrectionDisabled()

                Toggle(isOn: $settings.fetchesAutomatically) {
                    Text("Fetch automatically")
                    Text("Keeps behind counts current while Archipel is in front. Only remote branches are updated.")
                }
            }

            Section {
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
