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

#if DEBUG
private struct ProjectIconGallery: View {
    private static let sizes: [CGFloat] = [14, 18, 24, 48]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            row("Symbol") { size in
                ProjectIconTile(icon: .symbol("globe.europe.africa.fill"), image: nil, name: "Orbit", color: .blue, size: size)
            }
            row("Initial") { size in
                ProjectIconTile(icon: .automatic, image: nil, name: "blog", color: .orange, size: size)
            }
            row("Image") { size in
                ProjectIconTile(icon: .automatic, image: NSImage(named: NSImage.applicationIconName), name: "App", color: .gray, size: size)
            }
            row("Empty name") { size in
                ProjectIconTile(icon: .automatic, image: nil, name: "", color: .purple, size: size)
            }
            GridRow {
                Text("Tints").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Tint.allCases, id: \.self) { tint in
                        ProjectIconTile(icon: .automatic, image: nil, name: tint.displayName, color: tint.color)
                    }
                }
                .gridCellColumns(Self.sizes.count)
            }
        }
        .padding()
    }

    private func row(_ label: String, @ViewBuilder tile: @escaping (CGFloat) -> some View) -> some View {
        GridRow(alignment: .center) {
            Text(label).foregroundStyle(.secondary)
            ForEach(Self.sizes, id: \.self) { size in tile(size) }
        }
    }
}

#Preview("Tiles, light") {
    ProjectIconGallery()
        .preferredColorScheme(.light)
}

#Preview("Tiles, dark") {
    ProjectIconGallery()
        .preferredColorScheme(.dark)
}

#Preview("From the model") {
    let model = AppModel.preview()
    HStack(spacing: 12) {
        ProjectIconView(project: PreviewFixtures.appProject)
        ProjectIconView(project: PreviewFixtures.blogProject)
        ProjectIconView(project: PreviewFixtures.appProject, size: 32)
        ProjectIconView(project: PreviewFixtures.blogProject, size: 32)
    }
    .padding()
    .environment(model)
}
#endif
