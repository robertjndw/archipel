import Foundation
import Testing
import WebKit
@testable import EditorUI

struct PreviewSchemeTests {
    /// A repository with a document and an image, next to a folder that is not part of it.
    private struct Fixture {
        let base: URL
        var repository: URL { base.appending(path: "repo") }
        var outside: URL { base.appending(path: "outside") }
        var document: URL { repository.appending(path: "docs/README.md") }

        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "preview-scheme-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: repository.appending(path: "docs/images"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("# Title".utf8).write(to: document)
            try Data("png".utf8).write(to: repository.appending(path: "docs/images/a.png"))
            try Data("png".utf8).write(to: repository.appending(path: "logo.png"))
            try Data("secret".utf8).write(to: outside.appending(path: "secret.png"))
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    @Test func servesFilesInsideTheRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(PreviewScheme.containedFile(fixture.repository.appending(path: "docs/images/a.png"), in: fixture.repository) != nil)
        #expect(PreviewScheme.containedFile(fixture.repository.appending(path: "docs/../logo.png"), in: fixture.repository) != nil)
        #expect(PreviewScheme.containedFile(fixture.repository, in: fixture.repository) != nil)
    }

    @Test func refusesFilesOutsideTheRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(PreviewScheme.containedFile(fixture.outside.appending(path: "secret.png"), in: fixture.repository) == nil)
        #expect(PreviewScheme.containedFile(fixture.repository.appending(path: "../outside/secret.png"), in: fixture.repository) == nil)
        #expect(PreviewScheme.containedFile(URL(filePath: "/etc/hosts"), in: fixture.repository) == nil)
        #expect(PreviewScheme.containedFile(fixture.repository.appending(path: "missing.png"), in: fixture.repository) == nil)
    }

    @Test func aSiblingWithTheSamePrefixIsOutside() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sibling = fixture.base.appending(path: "repo-private")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sibling.appending(path: "a.png"))
        #expect(PreviewScheme.containedFile(sibling.appending(path: "a.png"), in: fixture.repository) == nil)
    }

    @Test func refusesSymlinksThatLeaveTheRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fileLink = fixture.repository.appending(path: "docs/images/leak.png")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: fixture.outside.appending(path: "secret.png"))
        let folderLink = fixture.repository.appending(path: "assets")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: fixture.outside)
        #expect(PreviewScheme.containedFile(fileLink, in: fixture.repository) == nil)
        #expect(PreviewScheme.containedFile(folderLink.appending(path: "secret.png"), in: fixture.repository) == nil)
    }

    @Test func followsSymlinksThatStayInside() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.repository.appending(path: "docs/logo.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.repository.appending(path: "logo.png"))
        let resolved = try #require(PreviewScheme.containedFile(link, in: fixture.repository))
        #expect(resolved.lastPathComponent == "logo.png")
        #expect(resolved.deletingLastPathComponent().lastPathComponent == "repo")
    }

    @Test func aRootReachedThroughASymlinkStillContainsItsFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.base.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repository)
        #expect(PreviewScheme.containedFile(fixture.repository.appending(path: "logo.png"), in: alias) != nil)
        #expect(PreviewScheme.containedFile(alias.appending(path: "logo.png"), in: fixture.repository) != nil)
    }

    @Test func servedRootIsTheRepositoryOrTheDocumentsFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        func path(_ url: URL) -> String { url.standardizedFileURL.path }
        #expect(path(PreviewScheme.servedRoot(for: fixture.document, root: fixture.repository)) == path(fixture.repository))
        #expect(path(PreviewScheme.servedRoot(for: fixture.document, root: nil)) == path(fixture.repository.appending(path: "docs")))
        // A file opened from elsewhere does not get to read the worktree, nor its own parents.
        let stray = fixture.outside.appending(path: "notes.md")
        try Data("# Notes".utf8).write(to: stray)
        #expect(path(PreviewScheme.servedRoot(for: stray, root: fixture.repository)) == path(fixture.outside))
    }

    @Test func roundTripsPathsThroughTheScheme() {
        let file = URL(filePath: "/tmp/my repo/docs/Read Me.md")
        let url = PreviewScheme.url(for: file)
        #expect(url.scheme == PreviewScheme.name)
        #expect(PreviewScheme.fileURL(for: url).path(percentEncoded: false) == "/tmp/my repo/docs/Read Me.md")
    }

    @Test func onlyTheDocumentsOwnAnchorsCountAsAnchors() throws {
        let document = PreviewScheme.url(for: URL(filePath: "/tmp/my repo/README.md"))
        #expect(PreviewScheme.isDocument(document, document))
        #expect(PreviewScheme.isAnchor(try #require(URL(string: "archipel-preview://local/tmp/my%20repo/README.md#install")), in: document))
        #expect(!PreviewScheme.isAnchor(document, in: document))
        #expect(!PreviewScheme.isAnchor(try #require(URL(string: "archipel-preview://local/tmp/my%20repo/OTHER.md#install")), in: document))
        #expect(!PreviewScheme.isAnchor(try #require(URL(string: "archipel-preview://local/tmp/my%20repo/README.md?x=1#install")), in: document))
        #expect(!PreviewScheme.isAnchor(try #require(URL(string: "archipel-preview://elsewhere/tmp/my%20repo/README.md#install")), in: document))
        #expect(!PreviewScheme.isAnchor(try #require(URL(string: "https://example.com/tmp/my%20repo/README.md#install")), in: document))
        #expect(!PreviewScheme.isDocument(try #require(URL(string: "https://example.com/")), document))
    }

    /// WebKit takes any of these for another URL and loads it, which would put the raw file
    /// where the preview is.
    @Test(arguments: [
        "archipel-preview://local/tmp/my%20repo/README%2Emd#x",
        "archipel-preview://local/tmp/my%20repo/%52EADME.md#x",
        "archipel-preview://local/tmp/my%20repo/./README.md#x",
        "archipel-preview://local/tmp/my%20repo//README.md#x",
        "archipel-preview://user@local/tmp/my%20repo/README.md#x",
        "archipel-preview://user:secret@local/tmp/my%20repo/README.md#x",
        "archipel-preview://local:8080/tmp/my%20repo/README.md#x",
        "archipel-preview://LOCAL/tmp/my%20repo/README.md#x",
        "archipel-preview://local/tmp/my%20repo/README.md?#x",
        "archipel-preview://local/tmp/my%20repo/README.md",
    ])
    func otherSpellingsOfTheDocumentAreNotAnchors(_ spelling: String) throws {
        let document = PreviewScheme.url(for: URL(filePath: "/tmp/my repo/README.md"))
        guard let url = URL(string: spelling) else { return }
        #expect(!PreviewScheme.isAnchor(url, in: document))
        #expect(!PreviewScheme.isAnchor(url, inDocumentLoadedAs: document.absoluteString))
    }

    @Test func anchorsAreComparedWithTheURLWebKitReported() throws {
        // Whatever WebKit made of the path when the document loaded is the spelling to match.
        let reported = "archipel-preview://local/tmp/caf%C3%A9/README.md"
        #expect(PreviewScheme.isAnchor(try #require(URL(string: reported + "#top")), inDocumentLoadedAs: reported))
        #expect(PreviewScheme.isAnchor(try #require(URL(string: reported + "#")), inDocumentLoadedAs: reported))
        #expect(!PreviewScheme.isAnchor(try #require(URL(string: "archipel-preview://local/tmp/caf%c3%a9/README.md#top")), inDocumentLoadedAs: reported))
    }

    @Test func theDocumentLoadNeedsTheOwnAuthority() throws {
        let document = PreviewScheme.url(for: URL(filePath: "/tmp/repo/README.md"))
        #expect(PreviewScheme.isDocument(try #require(URL(string: "archipel-preview://local/tmp/repo/README.md")), document))
        for other in ["archipel-preview://user@local/tmp/repo/README.md", "archipel-preview://local:1/tmp/repo/README.md", "archipel-preview://other/tmp/repo/README.md"] {
            #expect(!PreviewScheme.isDocument(try #require(URL(string: other)), document))
        }
    }

    // MARK: Navigation

    private static let document = PreviewScheme.url(for: URL(filePath: "/tmp/repo/README.md"))

    private func decide(
        _ url: String?,
        link: Bool = true,
        mainFrame: Bool = true,
        gate: Bool = false,
        loaded: String? = PreviewSchemeTests.document.absoluteString
    ) -> PreviewNavigation.Decision {
        PreviewNavigation.decide(
            url: url.flatMap(URL.init(string:)),
            isLinkActivated: link,
            isMainFrame: mainFrame,
            gateIsOpen: gate,
            documentURL: Self.document,
            loadedDocument: loaded
        )
    }

    @Test func theDocumentLoadsOnceThroughTheGate() {
        let document = Self.document.absoluteString
        #expect(decide(document, link: false, gate: true, loaded: nil) == .loadDocument(document))
        // Closed, a refresh to the same URL would show the raw file.
        #expect(decide(document, link: false, gate: false) == .cancel)
        #expect(decide(document, link: false, mainFrame: false, gate: true) == .cancel)
        #expect(decide("archipel-preview://local/tmp/repo/OTHER.md", link: false, gate: true) == .cancel)
        #expect(decide("https://example.com/", link: false, gate: true) == .cancel)
        // A click on a link to the document is a link like any other, gate or not.
        #expect(decide(document, link: true, gate: true) == .open(URL(filePath: "/tmp/repo/README.md")))
    }

    @Test func nothingThePageStartsItselfNavigates() {
        for url in ["https://example.com/", "archipel-preview://local/tmp/repo/OTHER.md", "about:blank", "data:text/html,x", "shortcuts://run"] {
            #expect(decide(url, link: false) == .cancel)
            #expect(decide(url, link: false, mainFrame: false) == .cancel)
        }
        #expect(decide(nil) == .cancel)
        #expect(decide(nil, link: false, gate: true) == .cancel)
    }

    @Test func anchorsScrollOnlyInTheMainFrame() {
        let anchor = Self.document.absoluteString + "#install"
        #expect(decide(anchor) == .scroll)
        #expect(decide(anchor, link: false) == .scroll)
        #expect(decide(anchor, link: false, mainFrame: false) == .cancel)
        // Not a scroll for WebKit, so not one here: it goes to the app as a link to the file.
        #expect(decide("archipel-preview://local/tmp/repo/README%2Emd#install") == .open(URL(filePath: "/tmp/repo/README.md")))
        #expect(decide("archipel-preview://local/tmp/repo/README%2Emd#install", link: false) == .cancel)
    }

    @Test func anchorsMatchWhatWebKitReportedForTheLoad() {
        let reported = "archipel-preview://local/tmp/repo/README.md"
        #expect(decide(reported + "#a", loaded: reported) == .scroll)
        #expect(decide(reported + "#a", loaded: "archipel-preview://local/tmp/repo/./README.md") != .scroll)
        // Before WebKit has reported anything, the URL the model asked for stands in.
        #expect(decide(Self.document.absoluteString + "#a", loaded: nil) == .scroll)
    }

    @Test func clickedLinksGoToTheAppAndNeverNavigate() {
        #expect(decide("archipel-preview://local/tmp/repo/docs/guide.md") == .open(URL(filePath: "/tmp/repo/docs/guide.md")))
        #expect(decide("https://example.com/a?b=c") == .open(URL(string: "https://example.com/a?b=c")!))
        #expect(decide("shortcuts://run-shortcut?name=x") == .open(URL(string: "shortcuts://run-shortcut?name=x")!))
        #expect(decide("file:///etc/passwd") == .open(URL(string: "file:///etc/passwd")!))
    }

    @Test(arguments: ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,x", "blob:https://example.com/1", "vbscript:x"])
    func scriptSchemesGoNowhere(_ url: String) {
        #expect(decide(url) == .cancel)
        #expect(decide(url, link: false) == .cancel)
    }

    @Test(arguments: ["archipel-preview://anyhost/etc/passwd", "archipel-preview://user@local/etc/passwd", "archipel-preview://local:80/etc/passwd", "archipel-preview:///etc/passwd"])
    func aPreviewLinkWithAnotherHostGoesNowhere(_ url: String) {
        #expect(decide(url) == .cancel)
    }

    // MARK: The page

    @Test func theDocumentCarriesThePolicyAndTheNonce() throws {
        let html = PreviewScheme.document(styleNonce: "nonce-1", css: "body { margin: 0; }")
        let policy = PreviewScheme.contentSecurityPolicy(styleNonce: "nonce-1")
        let meta = try #require(html.range(of: "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"))
        let style = try #require(html.range(of: "<style nonce=\"nonce-1\">body { margin: 0; }</style>"))
        // A policy only governs what comes after it.
        #expect(meta.upperBound <= style.lowerBound)
        #expect(html.components(separatedBy: "<style").count == 2)
        #expect(!html.contains("<script"))
        #expect(html.contains("<article id=\"content\"></article>"))
    }

    @MainActor
    @Test func pageScriptsAreOffAndTheHandlerIsContained() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = PreviewScheme.configuration(for: fixture.document, root: fixture.repository)
        #expect(configuration.defaultNavigationPreferences.allowsContentJavaScript == false)
        let scheme = try #require(URLScheme(PreviewScheme.name))
        let handler = try #require(configuration.urlSchemeHandlers[scheme] as? PreviewScheme.Handler)
        #expect(handler.root.standardizedFileURL.path == fixture.repository.standardizedFileURL.path)
        #expect(handler.document == fixture.document)
        #expect(handler.maximumSize == PreviewScheme.maximumServedSize)

        // Opened from outside the worktree, the document's own folder is all it gets.
        let stray = fixture.outside.appending(path: "notes.md")
        try Data("# Notes".utf8).write(to: stray)
        let strayHandler = try #require(PreviewScheme.configuration(for: stray, root: fixture.repository).urlSchemeHandlers[scheme] as? PreviewScheme.Handler)
        #expect(strayHandler.root.standardizedFileURL.path == fixture.outside.standardizedFileURL.path)
    }

    // MARK: The handler

    private func reply(_ handler: PreviewScheme.Handler, _ url: URL) async throws -> (mimeType: String?, data: Data) {
        var mimeType: String?
        var data = Data()
        for try await result in handler.reply(for: URLRequest(url: url)) {
            switch result {
            case .response(let response): mimeType = response.mimeType
            case .data(let chunk): data.append(chunk)
            @unknown default: break
            }
        }
        return (mimeType, data)
    }

    @Test func theHandlerServesImagesFromInsideTheRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let handler = PreviewScheme.Handler(root: fixture.repository, document: fixture.document)
        let served = try await reply(handler, PreviewScheme.url(for: fixture.repository.appending(path: "docs/images/a.png")))
        #expect(served.mimeType == "image/png")
        #expect(served.data == Data("png".utf8))
    }

    @Test func theHandlersReplyIsContained() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let handler = PreviewScheme.Handler(root: fixture.repository, document: fixture.document)
        let leak = fixture.repository.appending(path: "docs/images/leak.png")
        try FileManager.default.createSymbolicLink(at: leak, withDestinationURL: fixture.outside.appending(path: "secret.png"))
        let inside = PreviewScheme.url(for: fixture.repository.appending(path: "logo.png")).absoluteString
        let refused = [
            PreviewScheme.url(for: fixture.outside.appending(path: "secret.png")),
            PreviewScheme.url(for: fixture.repository.appending(path: "../outside/secret.png")),
            PreviewScheme.url(for: leak),
            PreviewScheme.url(for: URL(filePath: "/etc/hosts")),
            PreviewScheme.url(for: fixture.repository.appending(path: "missing.png")),
            // A folder is inside the root but is nothing to serve.
            PreviewScheme.url(for: fixture.repository.appending(path: "docs")),
            try #require(URL(string: inside.replacingOccurrences(of: "://local/", with: "://elsewhere/"))),
            try #require(URL(string: inside.replacingOccurrences(of: "://local/", with: "://user@local/"))),
            try #require(URL(string: inside.replacingOccurrences(of: "://local/", with: "://local:8080/"))),
        ]
        for url in refused {
            await #expect(throws: (any Error).self, "\(url)") { _ = try await reply(handler, url) }
        }
    }

    @Test func theHandlerNeverServesTheDocumentItself() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let handler = PreviewScheme.Handler(root: fixture.repository, document: fixture.document)
        let alias = fixture.repository.appending(path: "docs/alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.document)
        let hardLink = fixture.repository.appending(path: "copy.md")
        try FileManager.default.linkItem(at: fixture.document, to: hardLink)
        let document = PreviewScheme.url(for: fixture.document).absoluteString
        let spellings = [
            PreviewScheme.url(for: fixture.document),
            try #require(URL(string: document.replacingOccurrences(of: "README.md", with: "README%2Emd"))),
            try #require(URL(string: document.replacingOccurrences(of: "README.md", with: "./README.md"))),
            PreviewScheme.url(for: alias),
            PreviewScheme.url(for: hardLink),
        ]
        for url in spellings {
            await #expect(throws: (any Error).self, "\(url)") { _ = try await reply(handler, url) }
        }
    }

    /// A named pipe in a cloned repository would hold the read open for as long as nobody writes
    /// to it. Here a writer does turn up after a while, so a handler that tried to read the pipe
    /// would come back with its contents instead of refusing it.
    @Test func theHandlerServesOnlyRegularFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pipe = fixture.repository.appending(path: "pipe.png")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        let writer = open(pipe.path, O_RDWR | O_NONBLOCK)
        try #require(writer >= 0)
        _ = "png".withCString { write(writer, $0, 3) }
        let closer = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            close(writer)
        }
        defer { closer.cancel() }
        let handler = PreviewScheme.Handler(root: fixture.repository, document: fixture.document)
        await #expect(throws: URLError.self) { _ = try await reply(handler, PreviewScheme.url(for: pipe)) }
        _ = await closer.result
    }

    @Test func theHandlerRefusesFilesOverItsLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.repository.appending(path: "build.png")
        try Data(repeating: 1, count: 4097).write(to: file)
        var handler = PreviewScheme.Handler(root: fixture.repository, document: fixture.document)
        handler.maximumSize = 4096
        await #expect(throws: URLError.self) { _ = try await reply(handler, PreviewScheme.url(for: file)) }
        handler.maximumSize = 4097
        #expect(try await reply(handler, PreviewScheme.url(for: file)).data.count == 4097)
        #expect(PreviewScheme.maximumServedSize >= 20 * 1024 * 1024)
    }

    @Test func onlyImagesGetATypeOfTheirOwn() {
        #expect(PreviewScheme.Handler.mimeType(for: URL(filePath: "/r/a.png")) == "image/png")
        #expect(PreviewScheme.Handler.mimeType(for: URL(filePath: "/r/a.JPG")) == "image/jpeg")
        #expect(PreviewScheme.Handler.mimeType(for: URL(filePath: "/r/a.svg")) == "image/svg+xml")
        for name in ["a.html", "a.htm", "a.xhtml", "a.js", "a.mjs", "a.md", "a.css", "a.xml", "a.pdf", "a", "a.unknownext"] {
            #expect(PreviewScheme.Handler.mimeType(for: URL(filePath: "/r/\(name)")) == "application/octet-stream", "\(name)")
        }
    }

    @Test func policyDeniesByDefaultAndAllowsOnlyStylesAndImages() {
        let policy = PreviewScheme.contentSecurityPolicy(styleNonce: "abc")
        let directives = Dictionary(uniqueKeysWithValues: policy.split(separator: ";").map { directive in
            let words = directive.split(separator: " ").map(String.init)
            return (words[0], Array(words.dropFirst()))
        })
        #expect(directives["default-src"] == ["'none'"])
        #expect(directives["style-src"] == ["'nonce-abc'"])
        #expect(directives["img-src"] == ["archipel-preview:", "data:", "https:"])
        #expect(directives["form-action"] == ["'none'"])
        #expect(directives["base-uri"] == ["'none'"])
        // Everything not named falls back to default-src: scripts, frames, objects, fonts, media.
        #expect(directives.count == 5)
        #expect(!policy.contains("unsafe"))
        #expect(!policy.contains("http:"))
    }

    @Test func linkPolicyTrustsOnlyWebAndMail() throws {
        for trusted in ["https://example.com", "HTTP://example.com", "mailto:a@example.com"] {
            #expect(PreviewLinkPolicy.opensWithoutAsking(try #require(URL(string: trusted))))
        }
        for other in ["shortcuts://run-shortcut?name=x", "ssh://host", "smb://host/share", "file:///etc/hosts", "x-apple.systempreferences:x", "docs/guide.md"] {
            #expect(!PreviewLinkPolicy.opensWithoutAsking(try #require(URL(string: other))))
        }
    }

    // MARK: Link actions

    @Test func filesInsideTheWorktreeOpenAndOthersAsk() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.repository
        let inside = root.appending(path: "docs/images/a.png")
        #expect(PreviewLinkPolicy.action(for: inside, root: root) == .file(inside))
        // A broken link still belongs to the worktree.
        let missing = root.appending(path: "docs/not-there.md")
        #expect(PreviewLinkPolicy.action(for: missing, root: root) == .file(missing))
        #expect(PreviewLinkPolicy.action(for: root, root: root) == .file(root))

        func outside(_ link: URL) -> String? {
            guard case .fileOutsideRoot(let file) = PreviewLinkPolicy.action(for: link, root: root) else { return nil }
            return file.path(percentEncoded: false)
        }
        #expect(outside(URL(filePath: "/etc/passwd")) == "/private/etc/passwd")
        #expect(outside(try #require(URL(string: "file:///etc/passwd"))) == "/private/etc/passwd")
        #expect(outside(try #require(URL(string: "file://localhost/etc/passwd"))) == "/private/etc/passwd")
        let secret = try #require(outside(root.appending(path: "../outside/secret.png")))
        #expect(secret.hasSuffix("/outside/secret.png") && !secret.contains(".."))
        #expect(outside(fixture.base.appending(path: "repo-private/a.md")) != nil)
        // The question shows where a symlink leads, not what it is called.
        let link = root.appending(path: "docs/leak.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside.appending(path: "secret.png"))
        #expect(outside(link) == secret)
        let folder = root.appending(path: "assets")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: fixture.outside)
        #expect(outside(folder.appending(path: "not-there.md"))?.hasSuffix("/outside/not-there.md") == true)
        // Without a worktree nothing counts as inside.
        #expect(PreviewLinkPolicy.action(for: inside, root: nil) != .file(inside))
    }

    @Test func linkActionsByScheme() throws {
        let root = URL(filePath: "/tmp/repo")
        func action(_ link: String) throws -> PreviewLinkPolicy.Action {
            PreviewLinkPolicy.action(for: try #require(URL(string: link)), root: root)
        }
        #expect(try action("https://example.com/a") == .web(URL(string: "https://example.com/a")!))
        #expect(try action("HTTP://example.com") == .web(URL(string: "HTTP://example.com")!))
        #expect(try action("mailto:a@example.com") == .system(URL(string: "mailto:a@example.com")!))
        for asked in ["shortcuts://run-shortcut?name=x", "ssh://host", "smb://host/share", "x-apple.systempreferences:x", "vscode://file/etc/passwd", "tel:123"] {
            #expect(try action(asked) == .confirm(URL(string: asked)!))
        }
        for ignored in ["javascript:alert(1)", "data:text/html,x", "blob:x", "vbscript:x", "archipel-preview://local/etc/passwd", "https:///nohost", "file://fileserver/share/x.md", "docs/guide.md"] {
            #expect(try action(ignored) == .ignore, "\(ignored)")
        }
    }

    @Test func withoutACallerOnlyWebAndMailOpenAndFilesAreRevealed() throws {
        for trusted in ["https://example.com", "http://example.com", "mailto:a@example.com"] {
            let url = try #require(URL(string: trusted))
            #expect(PreviewLinkPolicy.defaultAction(for: url) == .open(url))
        }
        for name in ["setup.command", "Tool.app", "run.terminal", "Build.workflow", "notes.md"] {
            let file = URL(filePath: "/tmp/repo/\(name)")
            #expect(PreviewLinkPolicy.defaultAction(for: file) == .reveal(file))
        }
        let fileURL = try #require(URL(string: "file:///tmp/repo/setup.command"))
        #expect(PreviewLinkPolicy.defaultAction(for: fileURL) == .reveal(fileURL))
        for other in ["shortcuts://run-shortcut?name=x", "ssh://host", "javascript:alert(1)", "x-apple.systempreferences:x", "docs/guide.md"] {
            #expect(PreviewLinkPolicy.defaultAction(for: try #require(URL(string: other))) == .ignore)
        }
    }

    // MARK: The question

    @Test func handlerLocations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let home = fixture.base.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: "Applications/Mine.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: "Downloads/Other.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.repository.appending(path: "tools/Safari.app"), withIntermediateDirectories: true)
        func location(_ app: URL, root: URL? = fixture.repository) -> PreviewLinkPolicy.HandlerLocation {
            PreviewLinkPolicy.location(ofHandler: app, root: root, home: home)
        }
        #expect(location(URL(filePath: "/Applications/Safari.app")) == .standard)
        #expect(location(URL(filePath: "/System/Applications/Mail.app")) == .standard)
        #expect(location(URL(filePath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")) == .standard)
        #expect(location(home.appending(path: "Applications/Mine.app")) == .standard)
        guard case .elsewhere(let path) = location(home.appending(path: "Downloads/Other.app")) else {
            Issue.record("an app in Downloads is not in a standard place")
            return
        }
        #expect(path.hasSuffix("/home/Downloads/Other.app"))
        // A name that only starts like a standard folder.
        #expect(location(URL(filePath: "/ApplicationsEvil/Safari.app")) == .elsewhere("/ApplicationsEvil/Safari.app"))
        guard case .insideRoot = location(fixture.repository.appending(path: "tools/Safari.app")) else {
            Issue.record("an app in the worktree was not recognised")
            return
        }
        // Reached through a symlink that lives elsewhere, it is still the worktree's app.
        let alias = home.appending(path: "Applications/Safari.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repository.appending(path: "tools/Safari.app"))
        guard case .insideRoot = location(alias) else {
            Issue.record("a symlink hid an app in the worktree")
            return
        }
        // A worktree kept in an Applications folder does not make its apps standard.
        guard case .insideRoot = PreviewLinkPolicy.location(ofHandler: home.appending(path: "Applications/Mine.app"), root: home.appending(path: "Applications"), home: home) else {
            Issue.record("the worktree has to win over the standard folders")
            return
        }
        #expect(location(fixture.repository.appending(path: "tools/Safari.app"), root: nil) != .standard)
    }

    @Test func theQuestionNamesTheAppAndWhereItLives() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let home = fixture.base.appending(path: "home")
        let url = try #require(URL(string: "shortcuts://run-shortcut?name=x"))
        func prompt(_ handler: URL?, name: String? = "Safari") -> PreviewLinkPolicy.Prompt {
            PreviewLinkPolicy.prompt(forOpening: url, handler: handler, handlerName: name, root: fixture.repository, home: home)
        }

        let standard = prompt(URL(filePath: "/System/Applications/Shortcuts.app"), name: "Shortcuts")
        #expect(standard.canOpen)
        #expect(standard.title == "Open this link in Shortcuts?")
        #expect(standard.detail.hasPrefix("shortcuts://run-shortcut?name=x\n"))
        #expect(!standard.detail.contains("/System/Applications"))

        let elsewhere = prompt(URL(filePath: "/Users/Shared/Safari.app"))
        #expect(elsewhere.canOpen)
        #expect(elsewhere.title == "Open this link in Safari?")
        #expect(elsewhere.detail.contains("/Users/Shared/Safari.app"))
        #expect(elsewhere.detail.contains("not in an Applications folder"))

        let app = fixture.repository.appending(path: "tools/Safari.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let refused = prompt(app)
        #expect(!refused.canOpen)
        #expect(refused.title == "This link was not opened")
        #expect(refused.detail.contains("/repo/tools/Safari.app"))
        #expect(refused.detail.contains("shortcuts://run-shortcut?name=x"))

        let none = prompt(nil, name: nil)
        #expect(!none.canOpen)
        #expect(none.title == "No app can open this link")
        #expect(none.detail == "shortcuts://run-shortcut?name=x")
    }

    @Test func theQuestionAboutAFileShowsTheResolvedPath() {
        let prompt = PreviewLinkPolicy.prompt(forFileOutsideRoot: URL(filePath: "/private/etc/passwd"))
        #expect(prompt.canOpen)
        #expect(prompt.title == "Open a file outside this worktree?")
        #expect(prompt.detail.hasPrefix("/private/etc/passwd\n"))
    }

    @Test func longDestinationsAreCutWithTheirStartInView() throws {
        #expect(PreviewLinkPolicy.shortened("abc") == "abc")
        #expect(PreviewLinkPolicy.shortened(String(repeating: "a", count: 600)).count == 600)
        let long = "x-evil://run?" + String(repeating: "a", count: 1000)
        let short = PreviewLinkPolicy.shortened(long)
        #expect(short.hasPrefix("x-evil://run?aaa"))
        #expect(short.hasSuffix("... (413 more characters)"))
        #expect(PreviewLinkPolicy.shortened("abcdef", limit: 4) == "abcd... (2 more characters)")
        let prompt = PreviewLinkPolicy.prompt(forOpening: try #require(URL(string: long)), handler: URL(filePath: "/Applications/X.app"), handlerName: String(repeating: "N", count: 500), root: nil)
        #expect(prompt.detail.contains("... (413 more characters)"))
        #expect(prompt.title.count < 150)
    }

    // MARK: Opening in the default app

    @Test func filesThatRunAreNotHandedToTheSystem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.repository
        func file(_ name: String, executable: Bool = false) throws -> URL {
            let url = folder.appending(path: name)
            try Data("x".utf8).write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false)) }
            return url
        }
        for name in ["setup.command", "run.sh", "build.py", "app.min.js", "x.terminal", "x.scpt", "x.jar", "x.pkg", "x.dmg", "x.inetloc", "x.webloc", "x.tool"] {
            #expect(ExternalFileOpen.runsCodeWhenOpened(try file(name)), "\(name)")
        }
        #expect(ExternalFileOpen.runsCodeWhenOpened(try file("binary", executable: true)))
        #expect(ExternalFileOpen.runsCodeWhenOpened(try file("photo.png", executable: true)))
        for name in ["Tool.app", "Build.workflow"] {
            let bundle = folder.appending(path: name)
            try FileManager.default.createDirectory(at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
            #expect(ExternalFileOpen.runsCodeWhenOpened(bundle), "\(name)")
        }
        // A symlink is judged by what it leads to.
        let alias = folder.appending(path: "readme.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder.appending(path: "setup.command"))
        #expect(ExternalFileOpen.runsCodeWhenOpened(alias))
        #expect(ExternalFileOpen.runsCodeWhenOpened(folder.appending(path: "not-there.bin")))

        for name in ["data.bin", "archive.zip", "photo.jpg", "doc.pdf", "big.json", "table.sqlite", "font.ttf"] {
            #expect(!ExternalFileOpen.runsCodeWhenOpened(try file(name)), "\(name)")
        }
    }
}
