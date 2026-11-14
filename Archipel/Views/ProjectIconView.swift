import ArchipelCore
import SwiftUI

/// A project's icon at any size: its symbol, its image, or its initial on the project color.
struct ProjectIconView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var size: CGFloat = 18

    var body: some View {
        ProjectIconTile(
            icon: project.icon,
            image: model.projectIcons[project.id],
            name: project.name,
            color: model.tint(of: project).color,
            size: size
        )
    }
}

/// The drawing, without the model, so settings can show a choice before it is saved.
struct ProjectIconTile: View {
    let icon: ProjectIcon
    let image: NSImage?
    let name: String
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        Group {
            if case .symbol(let symbol) = icon {
                tile { Image(systemName: symbol).font(.system(size: size * 0.56, weight: .semibold)) }
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(shape)
            } else {
                tile {
                    Text(name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.26, style: .continuous) }

    private func tile(@ViewBuilder _ content: () -> some View) -> some View {
        shape
            .fill(color.gradient)
            .overlay { content().foregroundStyle(.white) }
    }
}
