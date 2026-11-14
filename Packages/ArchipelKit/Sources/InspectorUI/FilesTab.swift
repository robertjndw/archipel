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
    private(set) var children: [URL: [FileNode]] = [:]
    private(set) var rootError: String?
    private var expanded: Set<URL> = []

    init(root: URL) {
        self.root = root
    }

    /// Whether a listed URL is a folder, from the listings already loaded rather than another stat.
    func isDirectory(_ url: URL) -> Bool {
        children[url.deletingLastPathComponent()]?.first { $0.url == url }?.isDirectory ?? false
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
    let actions: InspectorActions
    @State private var selection: Set<URL> = []

    var body: some View {
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
        .safeAreaBar(edge: .top, spacing: 0) {
            InspectorHeader(refresh: refresh) {
                Label(model.root.lastPathComponent, systemImage: FileIcon.folder)
            }
        }
        .task { await model.refresh() }
        .onAppActivation(perform: refresh)
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
            Button("Open in Tab") { files.forEach { actions.openFile($0, false) } }
                .disabled(files.isEmpty)
            Button("Open in Default App") { FileActions.open(urls) }
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
