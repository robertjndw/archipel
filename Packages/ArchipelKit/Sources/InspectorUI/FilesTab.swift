import SwiftUI

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var id: URL { url }
}

@MainActor @Observable
final class FileTreeModel {
    let root: URL
    private(set) var children: [URL: [FileNode]] = [:]
    private(set) var rootError: String?
    private var expanded: Set<URL> = []

    init(root: URL) {
        self.root = root
    }

    func isExpanded(_ directory: URL) -> Bool {
        expanded.contains(directory)
    }

    func setExpanded(_ directory: URL, _ isExpanded: Bool) {
        if isExpanded {
            expanded.insert(directory)
            // Cached children show immediately; the reload catches anything that changed while collapsed.
            Task { await load(directory) }
        } else {
            expanded.remove(directory)
        }
    }

    /// Reloads only folders the user can currently see, so expansion state survives and collapsed
    /// subtrees cost nothing.
    func refresh() async {
        await load(root)
        for directory in expanded where isVisible(directory) {
            await load(directory)
        }
    }

    func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: base) else { return url.path }
        return components.dropFirst(base.count).joined(separator: "/")
    }

    func load(_ directory: URL) async {
        do {
            children[directory] = try await Self.contents(of: directory)
            if directory == root { rootError = nil }
        } catch {
            if directory == root {
                rootError = error.localizedDescription
            } else {
                children[directory] = []
            }
        }
    }

    private func isVisible(_ directory: URL) -> Bool {
        var parent = directory.deletingLastPathComponent()
        while parent.pathComponents.count > root.pathComponents.count {
            guard expanded.contains(parent) else { return false }
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

struct FilesTab: View {
    let model: FileTreeModel
    @State private var selection: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(refresh: refresh) {
                Label(model.root.lastPathComponent, systemImage: FileIcon.folder)
            }

            if let error = model.rootError {
                ContentUnavailableView("Can't Read Folder", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    FileTreeRows(directory: model.root, model: model)
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: URL.self) { urls in
                    contextMenu(for: urls)
                } primaryAction: { urls in
                    FileActions.open(Array(urls))
                }
            }
        }
        .task { await model.refresh() }
        .onAppActivation(perform: refresh)
    }

    @ViewBuilder
    private func contextMenu(for urls: Set<URL>) -> some View {
        if !urls.isEmpty {
            let urls = urls.sorted { $0.path < $1.path }
            Button("Open") { FileActions.open(urls) }
            Button("Reveal in Finder") { FileActions.reveal(urls) }
            Divider()
            Button("Copy Path") { FileActions.copy(urls.map(\.path)) }
            Button("Copy Relative Path") { FileActions.copy(urls.map(model.relativePath(of:))) }
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
        if let nodes = model.children[directory] {
            ForEach(nodes) { node in
                if node.isDirectory {
                    DisclosureGroup(isExpanded: expansion(of: node.url)) {
                        FileTreeRows(directory: node.url, model: model)
                    } label: {
                        FileRow(node: node)
                    }
                    .tag(node.url)
                } else {
                    FileRow(node: node)
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
