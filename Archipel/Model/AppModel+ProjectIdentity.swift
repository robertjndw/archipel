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
        WorktreeLocation.path(for: project, branch: branch, defaultRoot: settings.worktreesRoot, among: allProjects)
    }

    func worktreesFolder(for project: Project) -> URL {
        WorktreeLocation.parentFolder(for: project, defaultRoot: settings.worktreesRoot, among: allProjects)
    }

    /// Where the project's worktrees go under the default root when it has no folder of its own.
    /// Not simply `<root>/<name>`: see `WorktreeLocation.defaultParentFolder`.
    func defaultWorktreesFolder(for project: Project) -> URL {
        WorktreeLocation.defaultParentFolder(for: project, defaultRoot: settings.worktreesRoot, among: allProjects)
    }

    private var allProjects: [Project] {
        workspace.islands.flatMap(\.projects)
    }

    func loadProjectIcons() {
        let projects = allProjects
        ProjectIconCache.forget(allBut: Set(projects.map(\.id)))
        for project in projects { loadIcon(of: project) }
    }

    /// Fills `projectIcons` for the project. A missing entry means "draw the initial instead".
    func loadIcon(of project: Project) {
        let id = project.id
        let icon = project.icon
        if case .symbol = icon {
            projectIcons[id] = nil
            return
        }
        let folder = project.folderURL
        // Only an automatic icon is searched for, so only that search is worth remembering.
        let remembered = icon == .automatic ? ProjectIconCache.lookup(id, folder: folder) : nil
        let usesGit = isGitAvailable
        Task { [weak self] in
            let found = await ProjectIconFinder.find(icon, in: folder, remembered: remembered, usingGit: usesGit)
            if icon == .automatic, found.searched { ProjectIconCache.remember(found.file, for: id, folder: folder) }
            // The repository scan is slow; by now the user may have chosen another icon.
            guard let self, self.workspace.project(id: id)?.icon == icon else { return }
            self.projectIcons[id] = found.image
        }
    }
}

/// Where the icon search of each project ended, so a launch does not walk every repository again.
/// In UserDefaults like other state that only saves work: losing it costs one search.
nonisolated enum ProjectIconCache {
    enum Answer: Equatable, Sendable {
        case file(URL)
        /// The repository has no icon of its own.
        case nothing
    }

    private struct Entry: Codable {
        var folder: String
        var file: String?
        var searchedAt: Date
    }

    private static let key = "projectIcons.found"
    /// A repository can gain an icon, or a better one than the favicon found first. Searching again
    /// now and then picks that up without a search at every launch.
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Nil when the project has to be searched: never searched, searched too long ago, or moved.
    /// A remembered file that has since been deleted is found out by whoever tries to read it.
    static func lookup(_ id: Project.ID, folder: URL, defaults: UserDefaults = .standard) -> Answer? {
        guard let entry = entries(defaults)[id.uuidString], entry.folder == folder.path(percentEncoded: false),
              Date().timeIntervalSince(entry.searchedAt) < lifetime
        else { return nil }
        return entry.file.map { .file(URL(filePath: $0)) } ?? .nothing
    }

    static func remember(_ file: URL?, for id: Project.ID, folder: URL, defaults: UserDefaults = .standard) {
        var all = entries(defaults)
        all[id.uuidString] = Entry(folder: folder.path(percentEncoded: false), file: file?.path(percentEncoded: false), searchedAt: Date())
        save(all, defaults)
    }

    static func forget(allBut projects: Set<Project.ID>, defaults: UserDefaults = .standard) {
        let all = entries(defaults)
        let kept = all.filter { UUID(uuidString: $0.key).map(projects.contains) ?? false }
        if kept.count != all.count { save(kept, defaults) }
    }

    private static func entries(_ defaults: UserDefaults) -> [String: Entry] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private static func save(_ entries: [String: Entry], _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
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

    /// What `find(_:in:remembered:usingGit:)` came up with.
    struct Found: Sendable {
        var image: NSImage?
        /// The file in the repository the image came from; nil for an avatar or no image at all.
        var file: URL?
        /// True when the repository was searched, which is when the answer is worth remembering.
        var searched = false
    }

    /// The repository's own icon file. The walk for an app icon is the slow part; see `appIconFile`.
    private static func iconFile(in root: URL) -> (file: URL, image: NSImage)? {
        if let appIcon = appIconFile(under: root), let image = thumbnail(of: appIcon) { return (appIcon, image) }
        for path in wellKnownPaths {
            let url = root.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path), let image = thumbnail(of: url) { return (url, image) }
        }
        return nil
    }

    private static func findIcon(in root: URL, remembered: ProjectIconCache.Answer?, usingGit: Bool) async -> Found {
        var found = Found()
        // A remembered file that is gone or no longer an image means the repository changed.
        if case .file(let file) = remembered, let image = thumbnail(of: file) {
            return Found(image: image, file: file)
        }
        if remembered != .nothing {
            found.searched = true
            if let icon = iconFile(in: root) { return Found(image: icon.image, file: icon.file, searched: true) }
        }
        // Looking up the remote takes git, which must not be started on a Mac without it.
        if usingGit { found.image = await gitHubAvatar(for: root) }
        return found
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

    /// The image to draw for `icon`, or nil when it is a symbol or nothing was found.
    @concurrent
    static func image(for icon: ProjectIcon, in root: URL) async -> NSImage? {
        await find(icon, in: root, remembered: nil, usingGit: true).image
    }

    /// Like `image(for:in:)`, also saying where the image came from. `remembered` is where the last
    /// search of this repository ended, which saves searching it again.
    @concurrent
    static func find(_ icon: ProjectIcon, in root: URL, remembered: ProjectIconCache.Answer?, usingGit: Bool) async -> Found {
        switch icon {
        case .symbol: Found()
        case .image(let url): Found(image: thumbnail(of: url))
        case .automatic: await findIcon(in: root, remembered: remembered, usingGit: usingGit)
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
