import AppKit
import ArchipelCore
import GitKit

extension AppModel {
    func updateProject(_ id: Project.ID, _ change: (inout Project) -> Void) {
        let before = workspace.project(id: id)
        mutate { $0.updateProject(id: id, change) }
        guard let after = workspace.project(id: id) else { return }
        if before?.icon != after.icon || before?.folderURL != after.folderURL { loadIcon(of: after) }
    }

    /// A project's own color, or its island's when it has none.
    func tint(of project: Project) -> Tint {
        project.tint ?? workspace.island(containingProject: project.id)?.tint ?? .blue
    }

    /// Where a new worktree of this project on `branch` would be created.
    func worktreePath(for project: Project, branch: String) -> URL {
        WorktreeLocation.path(for: project, branch: branch, defaultRoot: settings.worktreesRoot)
    }

    func loadProjectIcons() {
        for project in workspace.islands.flatMap(\.projects) { loadIcon(of: project) }
    }

    /// Fills `projectIcons` for the project. A missing entry means "draw the initial instead".
    func loadIcon(of project: Project) {
        let id = project.id
        let icon = project.icon
        if case .symbol = icon {
            projectIcons[id] = nil
            return
        }
        Task { [weak self] in
            let image = await ProjectIconFinder.image(for: icon, in: project.folderURL)
            // The repository scan is slow; by now the user may have chosen another icon.
            guard let self, self.workspace.project(id: id)?.icon == icon else { return }
            self.projectIcons[id] = image
        }
    }
}

/// Looks for an image that already represents a repository: its app icon, favicon or logo, and
/// failing those the avatar of its owner on GitHub.
nonisolated enum ProjectIconFinder {
    /// Checked in order, relative to the repository root.
    private static let wellKnownPaths = [
        "icon.png", "logo.png", "logo.svg", "icon.svg",
        "assets/icon.png", "assets/logo.png", "assets/logo.svg",
        "resources/icon.png", "build/icon.png", "src-tauri/icons/icon.png",
        "public/icon.png", "public/logo.png", "public/logo.svg",
        "public/apple-touch-icon.png", "public/favicon.svg", "public/favicon.png", "public/favicon.ico",
        "app/icon.png", "app/icon.svg", "app/apple-icon.png", "app/favicon.ico",
        "src/app/icon.png", "src/app/icon.svg", "src/app/favicon.ico",
        "static/favicon.svg", "static/favicon.png", "static/favicon.ico",
        "docs/logo.png", "docs/logo.svg", ".github/logo.png", ".github/logo.svg",
        "favicon.svg", "favicon.png", "favicon.ico",
    ]

    private static let skippedFolders: Set<String> = [
        "node_modules", "Pods", "Carthage", "Vendor", "vendor", "build", "dist", "DerivedData", "target",
    ]

    @concurrent
    static func findIcon(in root: URL) async -> NSImage? {
        if let appIcon = appIconFile(under: root), let image = thumbnail(of: appIcon) { return image }
        for path in wellKnownPaths {
            let url = root.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path), let image = thumbnail(of: url) { return image }
        }
        return await gitHubAvatar(for: root)
    }

    /// The avatar of the repository's owner on GitHub, for a repository that ships no icon of its
    /// own. URLSession's cache keeps this from being a download on every launch.
    private static func gitHubAvatar(for root: URL) async -> NSImage? {
        guard let origin = await GitClient().originURL(in: root),
              let url = GitHubRemote(remoteURL: origin)?.avatarURL(size: 128),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data)
        else { return nil }
        return thumbnail(of: image)
    }

    @concurrent
    /// The image to draw for `icon`, or nil when it is a symbol or nothing was found.
    static func image(for icon: ProjectIcon, in root: URL) async -> NSImage? {
        switch icon {
        case .symbol: nil
        case .image(let url): thumbnail(of: url)
        case .automatic: await findIcon(in: root)
        }
    }

    /// The largest image of the first `AppIcon.appiconset` within a few levels of the root. The depth
    /// limit keeps this cheap in a monorepo.
    private static func appIconFile(under root: URL) -> URL? {
        let rootDepth = root.pathComponents.count
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if skippedFolders.contains(name) || url.pathComponents.count - rootDepth > 4 {
                enumerator?.skipDescendants()
                continue
            }
            guard name.hasSuffix(".appiconset") else { continue }
            let images = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let largest = images
                .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
                .max { size(of: $0) < size(of: $1) }
            if let largest { return largest }
            enumerator?.skipDescendants()
        }
        return nil
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Rendered once into a small bitmap, so a 1024 px app icon does not stay in memory at full size.
    /// The image keeps its proportions; a wide logo ends up letterboxed, not squashed.
    private static func thumbnail(of url: URL) -> NSImage? {
        NSImage(contentsOf: url).flatMap(thumbnail(of:))
    }

    private static func thumbnail(of source: NSImage) -> NSImage? {
        guard source.isValid, source.size.width > 0, source.size.height > 0 else { return nil }
        let side = 128
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        let scale = CGFloat(side) / max(source.size.width, source.size.height)
        let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let rect = NSRect(
            x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
            width: size.width, height: size.height
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        image.addRepresentation(bitmap)
        return image
    }
}
