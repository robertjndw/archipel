import SwiftUI

/// The context menu entries every folder in the sidebar offers, projects and worktrees alike.
struct FolderActions: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    /// Only the path can still be copied when the folder is gone.
    var isMissing = false

    var body: some View {
        Button("Show in Finder", systemImage: "folder") { model.revealInFinder(folder) }
            .disabled(isMissing)
        if let editor = model.preferredEditor {
            Button("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right") { model.openInEditor(folder) }
                .disabled(isMissing)
        }
        Button("Open in Terminal", systemImage: "apple.terminal") { model.openInTerminal(folder) }
            .disabled(isMissing)
        Button("Copy Path", systemImage: "document.on.document") { model.copyToPasteboard(folder.path) }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 6) {
        FolderActions(folder: PreviewFixtures.mainWorktree.path)
    }
    .buttonStyle(.borderless)
    .labelStyle(.titleAndIcon)
    .padding()
    .environment(AppModel.preview())
}
#endif
