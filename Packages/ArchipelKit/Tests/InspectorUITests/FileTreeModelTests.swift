import Foundation
import Observation
import Synchronization
import Testing
@testable import InspectorUI

@MainActor
final class FileTreeModelTests {
    let root: URL

    init() throws {
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        root = URL(filePath: temp).appending(path: "FileTreeModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Sources/App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "Sources/App/main.swift"))
        try Data().write(to: root.appending(path: ".env"))
        try Data().write(to: root.appending(path: "README.md"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func listsHiddenFilesButNotTheGitFolderAndFoldersFirst() async throws {
        let model = FileTreeModel(root: root)
        await model.refresh()
        let nodes = try #require(model.nodes(in: root))
        #expect(nodes.map(\.name) == ["Sources", ".env", "README.md"])
        #expect(nodes.map(\.isDirectory) == [true, false, false])
        #expect(model.rootError == nil)
    }

    @Test func aLinkBackUpTheTreeIsALeaf() async throws {
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Sources/loop"), withDestinationURL: root)
        let model = FileTreeModel(root: root)
        await model.load(root.appending(path: "Sources"))
        let loop = try #require(model.nodes(in: root.appending(path: "Sources"))?.first { $0.name == "loop" })
        #expect(!loop.isDirectory)
        #expect(!model.isDirectory(loop.url))
    }

    /// Folder URLs from a listing end in a slash, and `deletingLastPathComponent` adds one too.
    /// Whether one is there must not decide whether a folder is found.
    @Test func foldersAreFoundWithOrWithoutATrailingSlash() async throws {
        let model = FileTreeModel(root: root)
        await model.refresh()
        let sources = try #require(model.nodes(in: root)?.first { $0.name == "Sources" })
        #expect(sources.url.path().hasSuffix("/"))

        await model.load(sources.url)
        #expect(model.nodes(in: root.appending(path: "Sources")) != nil)
        #expect(model.nodes(in: URL(filePath: root.path + "/Sources/")) != nil)
        #expect(model.isDirectory(root.appending(path: "Sources")))
        #expect(model.isDirectory(sources.url))
        #expect(!model.isDirectory(root.appending(path: "README.md")))

        model.setExpanded(sources.url, false)
        model.setExpanded(root.appending(path: "Sources"), true)
        #expect(model.isExpanded(sources.url))
        model.setExpanded(sources.url, false)
        #expect(!model.isExpanded(root.appending(path: "Sources")))
    }

    @Test func anUnchangedListingDoesNotNotifyObservers() async throws {
        let model = FileTreeModel(root: root)
        await model.refresh()
        let notified = Mutex(false)
        withObservationTracking {
            _ = model.nodes(in: root)
            _ = model.rootError
        } onChange: {
            notified.withLock { $0 = true }
        }
        await model.refresh()
        #expect(!notified.withLock { $0 })

        try Data().write(to: root.appending(path: "new.txt"))
        await model.refresh()
        #expect(notified.withLock { $0 })
        #expect(model.nodes(in: root)?.contains { $0.name == "new.txt" } == true)
    }

    @Test func aRootThatCannotBeListedShowsAnErrorUntilItCanAgain() async throws {
        let missing = root.appending(path: "not-yet")
        let model = FileTreeModel(root: missing)
        await model.refresh()
        #expect(model.rootError != nil)
        #expect(model.nodes(in: missing) == nil)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        await model.refresh()
        #expect(model.rootError == nil)
        #expect(model.nodes(in: missing) == [])
    }

    @Test func aSubfolderThatVanishedListsAsEmpty() async throws {
        let model = FileTreeModel(root: root)
        let app = root.appending(path: "Sources/App")
        await model.load(app)
        #expect(model.nodes(in: app)?.count == 1)
        try FileManager.default.removeItem(at: app)
        await model.load(app)
        #expect(model.nodes(in: app) == [])
        #expect(model.rootError == nil)
    }

    @Test func aSubfolderThatCannotBeReadSaysSoUntilItCanAgain() async throws {
        let readable = Mutex(false)
        let root = URL(filePath: "/tree")
        let secrets = root.appending(path: "secrets")
        let model = FileTreeModel(root: root) { directory in
            if directory.lastPathComponent == "secrets", !readable.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return [FileNode(url: directory.appending(path: "file"), name: "file", isDirectory: false)]
        }
        await model.load(root)
        await model.load(secrets)
        // Nothing to list either way. The error is what tells this folder from an empty one.
        #expect(model.nodes(in: secrets) == [])
        #expect(model.listingError(in: secrets) != nil)
        #expect(model.listingError(in: root) == nil)
        #expect(model.rootError == nil)

        readable.withLock { $0 = true }
        await model.load(secrets)
        #expect(model.listingError(in: secrets) == nil)
        #expect(model.nodes(in: secrets)?.count == 1)
    }

    @Test func refreshReloadsOnlyFoldersThatCanBeSeen() async throws {
        let version = Mutex(1)
        let root = URL(filePath: "/tree")
        let sources = root.appending(path: "Sources")
        let app = sources.appending(path: "App")
        // Every folder holds one file named after the current version, plus the next folder down.
        let model = FileTreeModel(root: root) { directory in
            let current = version.withLock { $0 }
            var nodes = [FileNode(url: directory.appending(path: "v\(current)"), name: "v\(current)", isDirectory: false)]
            if directory.lastPathComponent == "tree" { nodes.insert(FileNode(url: sources, name: "Sources", isDirectory: true), at: 0) }
            if directory.lastPathComponent == "Sources" { nodes.insert(FileNode(url: app, name: "App", isDirectory: true), at: 0) }
            return nodes
        }
        // Expanding reloads the folder in its own task. Await both so neither lands on top of the
        // refresh below. Spelled with trailing slashes, the way folder URLs come out of a real listing.
        await model.setExpanded(URL(filePath: "/tree/Sources/"), true)?.value
        await model.setExpanded(URL(filePath: "/tree/Sources/App/"), true)?.value
        #expect(model.nodes(in: app)?.last?.name == "v1")

        version.withLock { $0 = 2 }
        await model.refresh()
        #expect(model.nodes(in: sources)?.last?.name == "v2")
        #expect(model.nodes(in: app)?.last?.name == "v2")

        // Collapsing Sources hides App, which stays expanded but is no longer worth listing.
        model.setExpanded(sources, false)
        version.withLock { $0 = 3 }
        await model.refresh()
        #expect(model.nodes(in: root)?.last?.name == "v3")
        #expect(model.isExpanded(app))
        #expect(model.nodes(in: app)?.last?.name == "v2")
    }
}
