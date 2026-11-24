import SwiftUI
import UISupport

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var id: URL { url }
}

@MainActor @Observable
final class FileTreeModel {
    let root: URL
    /// Keyed by `URL.pathKey`, not URL: `deletingLastPathComponent` adds a trailing slash, and a
    /// listing may or may not have one, so equal folders would not find each other as URLs.
    private var children: [String: [FileNode]] = [:]
    private(set) var rootError: String?
    /// Why a folder below the root could not be listed, by path key. It lists as empty, and
    /// without this an unreadable folder would look the same as one with nothing in it.
    private var listingErrors: [String: String] = [:]
    /// Path key to the URL to list.
    private var expanded: [String: URL] = [:]
    private let listDirectory: @Sendable (URL) async throws -> [FileNode]

    /// `listDirectory` is only replaced by previews, which must not read the disk.
    init(root: URL, listDirectory: @escaping @Sendable (URL) async throws -> [FileNode] = { try await FileTreeModel.contents(of: $0) }) {
        self.root = root
        self.listDirectory = listDirectory
    }

    /// Nil until the folder has been listed once.
    func nodes(in directory: URL) -> [FileNode]? {
        children[directory.pathKey]
    }

    func listingError(in directory: URL) -> String? {
        listingErrors[directory.pathKey]
    }

    /// Whether a listed URL is a folder, from the listings already loaded rather than another stat.
    func isDirectory(_ url: URL) -> Bool {
        let key = url.pathKey
        return children[url.deletingLastPathComponent().pathKey]?.first { $0.url.pathKey == key }?.isDirectory ?? false
    }

    func isExpanded(_ directory: URL) -> Bool {
        expanded[directory.pathKey] != nil
    }

    func setExpanded(_ directory: URL, _ isExpanded: Bool) {
        if isExpanded {
            expanded[directory.pathKey] = directory
            // Cached children show immediately; the reload catches anything that changed while collapsed.
            Task { await load(directory) }
        } else {
            expanded[directory.pathKey] = nil
        }
    }

    /// Reloads only folders the user can currently see, so expansion state survives and collapsed
    /// subtrees cost nothing.
    func refresh() async {
        await load(root)
        for directory in expanded.values where isVisible(directory) {
            await load(directory)
        }
    }

    func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: base) else { return url.path }
        return components.dropFirst(base.count).joined(separator: "/")
    }

    /// Every row reads `children`, so an assignment of an unchanged listing would re-render each
    /// expanded folder once per folder refreshed. Only real changes are written.
    func load(_ directory: URL) async {
        let key = directory.pathKey
        let isRoot = key == root.pathKey
        do {
            let nodes = try await listDirectory(directory)
            if children[key] != nodes { children[key] = nodes }
            if isRoot, rootError != nil { rootError = nil }
            if listingErrors[key] != nil { listingErrors[key] = nil }
        } catch {
            let message = error.localizedDescription
            if isRoot {
                if rootError != message { rootError = message }
            } else {
                if children[key] != [] { children[key] = [] }
                if listingErrors[key] != message { listingErrors[key] = message }
            }
        }
    }

    private func isVisible(_ directory: URL) -> Bool {
        var parent = directory.deletingLastPathComponent()
        while parent.pathComponents.count > root.pathComponents.count {
            guard expanded[parent.pathKey] != nil else { return false }
            parent = parent.deletingLastPathComponent()
        }
        return true
    }

    /// Symlinks report as non-directories here (the key is read on the link itself), so a link back up
    /// the tree is shown as a leaf instead of an endless outline.
    @concurrent
    nonisolated static func contents(of directory: URL) async throws -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        return urls
            .filter { $0.lastPathComponent != ".git" }
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
                return FileNode(url: url, name: url.lastPathComponent, isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

extension URL {
    /// The standardized path without a trailing slash, so `/a/b` and `/a/b/` compare equal.
    var pathKey: String {
        var path = standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

struct FilesTab: View {
    let model: FileTreeModel
    let actions: InspectorActions
    @State private var selection: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(refresh: refresh) {
                Label(model.root.lastPathComponent, systemImage: FileIcon.folder)
            }
            list
        }
        // Slower than the Changes tab: this lists folders rather than asking git, and an unchanged
        // listing writes nothing, so the poll is only there to pick up files an agent creates.
        .refreshing(every: .seconds(5)) { await model.refresh() }
    }

    private var list: some View {
        Group {
            if let error = model.rootError {
                ContentUnavailableView("Can't Read Folder", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    FileTreeRows(directory: model.root, model: model)
                }
                .listStyle(.sidebar)
                .compactRows()
                .scrollEdgeFade()
                .contextMenu(forSelectionType: URL.self) { urls in
                    contextMenu(for: urls)
                } primaryAction: { urls in
                    open(urls)
                }
                .onChange(of: selection) { _, selection in
                    // Clicking or arrowing onto a file previews it; folders only expand and collapse.
                    guard selection.count == 1, let url = selection.first, !model.isDirectory(url) else { return }
                    actions.openFile(url, true)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Double click or Return: files open for keeps, folders toggle.
    private func open(_ urls: Set<URL>) {
        for url in urls.sorted(by: { $0.path < $1.path }) {
            if model.isDirectory(url) {
                model.setExpanded(url, !model.isExpanded(url))
            } else {
                actions.openFile(url, false)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for urls: Set<URL>) -> some View {
        if !urls.isEmpty {
            let urls = urls.sorted { $0.path < $1.path }
            let files = urls.filter { !model.isDirectory($0) }
            Button("Open in Tab", systemImage: "doc") { files.forEach { actions.openFile($0, false) } }
                .disabled(files.isEmpty)
            Button("Open in Default App", systemImage: "arrow.up.forward.app") { FileActions.open(urls) }
            Button("Show in Finder", systemImage: "folder") { FileActions.reveal(urls) }
            Divider()
            Button("Copy Path", systemImage: "document.on.document") { FileActions.copy(urls.map(\.path)) }
            Button("Copy Relative Path", systemImage: "document.on.document") { FileActions.copy(urls.map(model.relativePath(of:))) }
        }
    }

    private func refresh() {
        Task { await model.refresh() }
    }
}

private struct FileTreeRows: View {
    let directory: URL
    let model: FileTreeModel

    var body: some View {
        if let error = model.listingError(in: directory) {
            Label("Can't read this folder", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .help(error)
        } else if let nodes = model.nodes(in: directory) {
            ForEach(nodes) { node in
                if node.isDirectory {
                    DisclosureGroup(isExpanded: expansion(of: node.url)) {
                        FileTreeRows(directory: node.url, model: model)
                    } label: {
                        FileRow(node: node)
                            .draggable(node.url)
                    }
                    .tag(node.url)
                } else {
                    FileRow(node: node)
                        .draggable(node.url)
                        .tag(node.url)
                }
            }
        } else if directory != model.root {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func expansion(of url: URL) -> Binding<Bool> {
        Binding { model.isExpanded(url) } set: { model.setExpanded(url, $0) }
    }
}

private struct FileRow: View {
    let node: FileNode

    var body: some View {
        Label {
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                // Dimmed like hidden files in Finder.
                .foregroundStyle(node.name.hasPrefix(".") ? .secondary : .primary)
        } icon: {
            if node.isDirectory {
                Image(systemName: FileIcon.folder)
            } else {
                Image(systemName: FileIcon.symbol(for: node.name))
                    .foregroundStyle(.secondary)
            }
        }
        .help(node.url.path)
    }
}

#if DEBUG
#Preview("Expanded") {
    FilesTab(model: PreviewSamples.fileTree(expanding: ["Sources", "Sources/App"]), actions: PreviewSamples.actions)
        .frame(width: 300, height: 480)
        .background(Color.inspectorBackground)
}

#Preview("Expanded, Dark") {
    FilesTab(model: PreviewSamples.fileTree(expanding: ["Sources", "Sources/App", "Sources/Resources"]), actions: PreviewSamples.actions)
        .frame(width: 300, height: 480)
        .background(Color.inspectorBackground)
        .preferredColorScheme(.dark)
}

#Preview("Collapsed") {
    FilesTab(model: PreviewSamples.fileTree(), actions: PreviewSamples.actions)
        .frame(width: 300, height: 320)
        .background(Color.inspectorBackground)
}

#Preview("Can't Read Subfolder") {
    let model = FileTreeModel(root: PreviewSamples.root) { directory in
        if directory.lastPathComponent == "Sources" { throw CocoaError(.fileReadNoPermission) }
        return try await PreviewSamples.listDirectory(directory)
    }
    model.setExpanded(PreviewSamples.root.appending(path: "Sources", directoryHint: .isDirectory), true)
    return FilesTab(model: model, actions: PreviewSamples.actions)
        .frame(width: 300, height: 320)
        .background(Color.inspectorBackground)
}

#Preview("Can't Read Folder") {
    let model = FileTreeModel(root: PreviewSamples.root) { _ in
        throw CocoaError(.fileReadNoPermission)
    }
    FilesTab(model: model, actions: PreviewSamples.actions)
        .frame(width: 300, height: 320)
        .background(Color.inspectorBackground)
}
#endif
