import SwiftUI

extension View {
    /// Folders dragged from Finder become projects of the selected island. Anything else is
    /// refused, so the drop never highlights for files or for the app's own tab drags (which
    /// travel as plain strings).
    func folderDropsAddProjects(to model: AppModel) -> some View {
        modifier(FolderDropModifier(model: model))
    }
}

private struct FolderDropModifier: ViewModifier {
    let model: AppModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let folders = urls.filter(\.isExistingFolder)
                guard !folders.isEmpty else { return false }
                model.addProjects(folders: folders)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 2)
                        .background(.tint.opacity(0.08), in: .rect(cornerRadius: 10))
                        .padding(4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

private extension URL {
    var isExistingFolder: Bool {
        isFileURL && (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
