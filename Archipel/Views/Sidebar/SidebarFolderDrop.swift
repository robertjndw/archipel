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
    @Environment(\.windowCornerRadius) private var windowRadius

    private static let inset: CGFloat = 4

    /// The outline's leading corners sit in the window's corners and nest in them; the trailing
    /// ones face the content and take the plain control radius. The sidebar starts below the top
    /// line's inset, which puts the top corner that much further from the window's.
    private var outline: UnevenRoundedRectangle {
        let top = Self.inset + WindowButtons.topInset(for: model.settings.paneStyle)
        return UnevenRoundedRectangle(
            topLeadingRadius: max(windowRadius - top, 4),
            bottomLeadingRadius: windowRadius - Self.inset,
            bottomTrailingRadius: Chrome.controlRadius,
            topTrailingRadius: Chrome.controlRadius,
            style: .continuous
        )
    }

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
                    outline
                        .fill(.tint.opacity(0.08))
                        .strokeBorder(.tint, lineWidth: 2)
                        .padding(Self.inset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(Motion.hover, value: isTargeted)
    }
}

private extension URL {
    var isExistingFolder: Bool {
        isFileURL && (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
