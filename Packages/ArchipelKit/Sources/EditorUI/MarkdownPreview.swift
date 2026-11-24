import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Renders the buffer, not the file, so unsaved edits show too. Renders again whenever the file
/// changes on disk.
struct MarkdownPreview: View {
    let buffer: TextBuffer
    /// The repository or worktree the file belongs to, when the caller knows it.
    var root: URL?
    let onOpenLink: (URL) -> Void
    @State private var model: MarkdownPreviewModel?

    var body: some View {
        Group {
            if let model {
                WebView(model.page)
                    .webViewContentBackground(.hidden)
            } else {
                Color.clear
            }
        }
        .task(id: buffer.revision) {
            let model = model ?? MarkdownPreviewModel(fileURL: buffer.fileURL, root: root, onOpenLink: onOpenLink)
            self.model = model
            let html = await Self.render(buffer.text)
            guard !Task.isCancelled else { return }
            await model.show(html)
        }
    }

    private static func render(_ text: String) async -> String {
        let blocks = await Self.codeBlocks(in: text)
        var highlights: [Int: [HighlightRun]] = [:]
        for (index, block) in blocks.enumerated() {
            // Every keystroke starts a new render; the one it replaces should stop here rather
            // than highlight the rest of a long document first.
            if Task.isCancelled { return "" }
            if let runs = await SyntaxHighlighter.shared.runs(for: block.code, grammar: block.language) {
                highlights[index] = runs
            }
        }
        return await Self.html(for: text, highlights: highlights)
    }

    @concurrent
    private nonisolated static func codeBlocks(in text: String) async -> [MarkdownHTML.CodeBlock] {
        MarkdownHTML.codeBlocks(in: text)
    }

    @concurrent
    private nonisolated static func html(for text: String, highlights: [Int: [HighlightRun]]) async -> String {
        MarkdownHTML.render(text, highlights: highlights)
    }
}

/// The page loads once with an empty article. Later renders only swap the article's contents, so
/// a change on disk doesn't throw the reader back to the top.
@MainActor
private final class MarkdownPreviewModel {
    let page: WebPage
    private let baseURL: URL
    private let loadGate = DocumentLoadGate()
    /// Fresh for every preview, so a `<style>` in the Markdown cannot name it and pass the policy.
    private let styleNonce = UUID().uuidString
    private var isReady = false
    private var isLoading = false
    private var shown: String?
    private var latest: String?

    init(fileURL: URL, root: URL?, onOpenLink: @escaping (URL) -> Void) {
        let baseURL = PreviewScheme.url(for: fileURL)
        self.baseURL = baseURL
        page = WebPage(
            configuration: PreviewScheme.configuration(for: fileURL, root: root),
            navigationDecider: LinkDecider(documentURL: baseURL, loadGate: loadGate, onOpenLink: onOpenLink)
        )
        Task { [weak self] in await self?.flush() }
    }

    func show(_ html: String) async {
        latest = html
        await flush()
    }

    private func flush() async {
        if !isReady {
            // A load that is under way pushes `latest` itself once it is done.
            guard !isLoading, await loadDocument() else { return }
        }
        guard let html = latest, html != shown else { return }
        if await inject(html) {
            shown = html
            return
        }
        // The call fails when the web process is gone or the page has lost its article. Either
        // way what is on screen is not this render, so start over from the empty document rather
        // than leave it there. If that fails too, the next render tries again.
        guard !isLoading, await loadDocument(), let html = latest, await inject(html) else { return }
        shown = html
    }

    private func loadDocument() async -> Bool {
        isReady = false
        shown = nil
        isLoading = true
        defer { isLoading = false }
        loadGate.isOpen = true
        defer { loadGate.isOpen = false }
        do {
            for try await _ in page.load(html: PreviewScheme.document(styleNonce: styleNonce, css: MarkdownStyle.css), baseURL: baseURL) {}
        } catch {
            return false
        }
        isReady = true
        return true
    }

    private func inject(_ html: String) async -> Bool {
        do {
            _ = try await page.callJavaScript("document.getElementById('content').innerHTML = html", arguments: ["html": html])
            return true
        } catch {
            return false
        }
    }
}

/// Open only while the model loads its own document, so the decider can tell that load from a
/// navigation the page came up with.
@MainActor
private final class DocumentLoadGate {
    var isOpen = false
    /// The document's URL as WebKit spelled it when the load went through.
    var loadedDocument: String?
}

/// Opens links the way the rest of the app does instead of navigating the preview away. Anchors
/// within the document still scroll.
private struct LinkDecider: WebPage.NavigationDeciding {
    let documentURL: URL
    let loadGate: DocumentLoadGate
    let onOpenLink: (URL) -> Void

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        let decision = PreviewNavigation.decide(
            url: action.request.url,
            isLinkActivated: action.navigationType == .linkActivated,
            isMainFrame: action.target?.isMainFrame == true,
            gateIsOpen: loadGate.isOpen,
            documentURL: documentURL,
            loadedDocument: loadGate.loadedDocument
        )
        switch decision {
        case .scroll:
            return .allow
        case .loadDocument(let reported):
            // The gate closes with the first use; a refresh to the document's own URL would
            // otherwise load the raw file.
            loadGate.isOpen = false
            loadGate.loadedDocument = reported
            return .allow
        case .open(let url):
            onOpenLink(url)
            return .cancel
        case .cancel:
            return .cancel
        }
    }
}

/// What the preview does with a navigation, kept apart from WebKit's types so it can be tested.
enum PreviewNavigation {
    enum Decision: Equatable {
        /// A fragment of the document that is showing.
        case scroll
        /// The model's own load of the empty document, with the URL as WebKit spelled it.
        case loadDocument(String)
        /// Nothing loads; the link goes to the app.
        case open(URL)
        case cancel
    }

    /// `loadedDocument` is what an earlier `.loadDocument` carried, nil before the first load.
    static func decide(
        url: URL?,
        isLinkActivated: Bool,
        isMainFrame: Bool,
        gateIsOpen: Bool,
        documentURL: URL,
        loadedDocument: String?
    ) -> Decision {
        guard let url else { return .cancel }
        // Scrolling within the document, however it was started.
        if isMainFrame, PreviewScheme.isAnchor(url, inDocumentLoadedAs: loadedDocument ?? documentURL.absoluteString) { return .scroll }
        guard isLinkActivated else {
            // Everything else the page can start by itself: a meta refresh, a form, a frame. The
            // Markdown is not trusted, so none of it may replace the preview.
            if gateIsOpen, isMainFrame, PreviewScheme.isDocument(url, documentURL) { return .loadDocument(url.absoluteString) }
            return .cancel
        }
        guard let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == PreviewScheme.name {
            // `//elsewhere/etc/hosts` resolves to this scheme with another host. The path alone
            // would then name a local file the link never spelled out.
            guard PreviewScheme.hasOwnAuthority(url) else { return .cancel }
            return .open(PreviewScheme.fileURL(for: url))
        }
        return HTMLSanitizer.scriptSchemes.contains(scheme) ? .cancel : .open(url)
    }
}

/// `archipel-preview://local/<absolute path>` stands for that file on disk.
enum PreviewScheme {
    static let name = "archipel-preview"
    static let host = "local"

    static func url(for fileURL: URL) -> URL {
        URL(string: "\(name)://\(host)")!.appending(path: fileURL.path(percentEncoded: false))
    }

    @MainActor
    static func configuration(for fileURL: URL, root: URL?) -> WebPage.Configuration {
        var configuration = WebPage.Configuration()
        // The Markdown's own HTML can carry scripts. Ours run anyway: this only stops the page's.
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        // Relative image and link paths resolve against the file and are served from disk here.
        // A file URL as the base would only reach the file's own folder, not `../images`.
        if let scheme = URLScheme(name) {
            configuration.urlSchemeHandlers[scheme] = Handler(root: servedRoot(for: fileURL, root: root), document: fileURL)
        }
        return configuration
    }

    /// The empty page a preview starts from. The policy has to come before the stylesheet, and
    /// the stylesheet has to carry the nonce the policy names, or the page comes up unstyled.
    static func document(styleNonce: String, css: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(styleNonce: styleNonce))">
        <style nonce="\(styleNonce)">\(css)</style>
        </head>
        <body><article id="content"></article></body>
        </html>
        """
    }

    static func fileURL(for url: URL) -> URL {
        URL(filePath: url.path(percentEncoded: false))
    }

    /// Denies everything and then allows what the preview shows: its own stylesheet, and images
    /// from disk, from `data:` and over https, so badges and screenshots work. No scripts are
    /// listed because the page has none; what the app runs through the web view is not subject
    /// to the policy. Style attributes and `<style>` elements without the nonce do not apply.
    static func contentSecurityPolicy(styleNonce: String) -> String {
        "default-src 'none'; style-src 'nonce-\(styleNonce)'; img-src \(name): data: https:; form-action 'none'; base-uri 'none'"
    }

    /// Whether WebKit's URL for the model's own load is the one the model asked for. Compares
    /// paths rather than strings, because WebKit and Foundation do not percent-encode a path the
    /// same way. Only good for that one load: see `isAnchor` for why links need more.
    static func isDocument(_ url: URL, _ documentURL: URL) -> Bool {
        url.scheme == documentURL.scheme && hasOwnAuthority(url) && url.query() == nil && url.fragment() == nil
            && url.path(percentEncoded: false) == documentURL.path(percentEncoded: false)
    }

    /// The preview's own host and nothing else in the authority.
    static func hasOwnAuthority(_ url: URL) -> Bool {
        url.host() == host && url.user() == nil && url.password() == nil && url.port == nil
    }

    /// Whether following `url` only scrolls the document that was loaded as `loaded`.
    ///
    /// WebKit decides that by comparing the two URLs as strings, fragment aside. So must this:
    /// `README%2Emd#x` names the same file as `README.md#x`, but to WebKit it is another URL,
    /// and allowing it would load the raw file in place of the preview.
    static func isAnchor(_ url: URL, inDocumentLoadedAs loaded: String) -> Bool {
        guard hasOwnAuthority(url) else { return false }
        let text = url.absoluteString
        guard let hash = text.firstIndex(of: "#") else { return false }
        return text[..<hash] == loaded
    }

    static func isAnchor(_ url: URL, in documentURL: URL) -> Bool {
        isAnchor(url, inDocumentLoadedAs: documentURL.absoluteString)
    }

    /// The folder the preview may read files from: the repository or worktree when the document
    /// is inside it, otherwise only the document's own folder.
    static func servedRoot(for fileURL: URL, root: URL?) -> URL {
        if let root, containedFile(fileURL, in: root) != nil { return root }
        return fileURL.deletingLastPathComponent()
    }

    /// The file with its symlinks resolved, if it then still lies inside `root`. A link in the
    /// repository that points outside it is not part of the repository.
    static func containedFile(_ fileURL: URL, in root: URL) -> URL? {
        guard let file = realPath(fileURL), let root = realPath(root) else { return nil }
        guard file == root || file.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return URL(filePath: file)
    }

    static func realPath(_ url: URL) -> String? {
        guard let pointer = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Where `url` leads once symlinks are followed, also when the file itself does not exist:
    /// then the nearest folder that does is resolved and the rest appended.
    static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let real = realPath(existing) {
                return missing.reversed().reduce(URL(filePath: real)) { $0.appending(path: $1) }.path(percentEncoded: false)
            }
            guard existing.pathComponents.count > 1 else { return url.standardizedFileURL.path(percentEncoded: false) }
            missing.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
    }

    /// Whether `url` leads into `root`, judged like `containedFile` but without needing the
    /// file to exist.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let file = resolvedPath(url)
        let root = resolvedPath(root)
        return file == root || file.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Screen recordings in a README run to tens of megabytes. Past this it is not an image
    /// anybody meant to show, and it would be read into memory whole.
    static let maximumServedSize = 50 * 1024 * 1024

    struct Handler: URLSchemeHandler {
        let root: URL
        /// The file being previewed.
        let document: URL
        var maximumSize = PreviewScheme.maximumServedSize

        struct Resource {
            var data: Data
            var mimeType: String
        }

        func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
            AsyncThrowingStream { continuation in
                Task.detached {
                    do {
                        guard let url = request.url else { throw URLError(.badURL) }
                        let resource = try resource(for: url)
                        let response = URLResponse(url: url, mimeType: resource.mimeType, expectedContentLength: resource.data.count, textEncodingName: nil)
                        continuation.yield(.response(response))
                        continuation.yield(.data(resource.data))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        func resource(for url: URL) throws -> Resource {
            guard PreviewScheme.hasOwnAuthority(url),
                  let file = PreviewScheme.containedFile(PreviewScheme.fileURL(for: url), in: root)
            else { throw URLError(.noPermissionsToReadFile) }
            // The page itself is loaded from a string and never asks for its own file. A request
            // for it is the document trying to put its raw source where the preview is.
            guard !Self.isSameFile(file, document) else { throw URLError(.noPermissionsToReadFile) }
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw URLError(.noPermissionsToReadFile)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            // One byte more than allowed tells a file that is too large from one that just fits,
            // whatever its size was a moment ago.
            let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
            guard data.count <= maximumSize else { throw URLError(.dataLengthExceedsMaximum) }
            return Resource(data: data, mimeType: Self.mimeType(for: file))
        }

        /// Only images get a type of their own, since images are all the page may load. Anything
        /// else goes out as bytes: a type taken from the name would let `x.html` come back as a
        /// page if something ever navigated to it.
        static func mimeType(for file: URL) -> String {
            guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
                  let mimeType = type.preferredMIMEType
            else { return "application/octet-stream" }
            return mimeType
        }

        /// By inode rather than by path: a hard link, or other letter case on a volume that
        /// ignores it, is still the same file.
        private static func isSameFile(_ first: URL, _ second: URL) -> Bool {
            var firstInfo = stat()
            var secondInfo = stat()
            guard stat(first.path(percentEncoded: false), &firstInfo) == 0,
                  stat(second.path(percentEncoded: false), &secondInfo) == 0
            else { return false }
            return firstInfo.st_dev == secondInfo.st_dev && firstInfo.st_ino == secondInfo.st_ino
        }
    }
}

/// Close to GitHub's rendering, set in the system font, with code coloured like the editor.
@MainActor
private enum MarkdownStyle {
    static let css: String = base + syntax

    private static let base = """
        :root { color-scheme: light dark; }
        html { background: transparent; }
        body {
            margin: 0; padding: 24px 32px 48px;
            font: 14px/1.6 -apple-system, sans-serif;
            color: -apple-system-label;
            -webkit-font-smoothing: antialiased;
        }
        article { max-width: 860px; margin: 0 auto; overflow-wrap: break-word; }
        article > :first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 { margin: 1.5em 0 0.6em; font-weight: 600; line-height: 1.25; }
        h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid -apple-system-separator; }
        h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid -apple-system-separator; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1em; }
        h5 { font-size: 0.875em; }
        h6 { font-size: 0.85em; color: -apple-system-secondary-label; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: -apple-system-control-accent; text-decoration: none; }
        a:hover { text-decoration: underline; }
        ul, ol { padding-left: 2em; }
        li + li { margin-top: 0.25em; }
        li > p { margin: 0; }
        li.task > p:first-of-type { display: inline; }
        li > ul, li > ol { margin: 0.25em 0 0; }
        li.task { list-style: none; }
        li.task > input { margin: 0 0.4em 0 -1.4em; vertical-align: middle; }
        blockquote { margin-left: 0; padding: 0 1em; color: -apple-system-secondary-label; border-left: 0.25em solid -apple-system-separator; }
        hr { height: 1px; border: 0; background: -apple-system-separator; margin: 1.5em 0; }
        img { max-width: 100%; }
        code, pre { font: 12px/1.5 ui-monospace, monospace; }
        code { padding: 0.15em 0.35em; border-radius: 5px; background: rgba(128, 128, 128, 0.14); }
        pre { padding: 12px 16px; overflow-x: auto; border-radius: 8px; background: rgba(128, 128, 128, 0.1); }
        pre code { padding: 0; background: none; border-radius: 0; }
        table { border-collapse: collapse; display: block; width: max-content; max-width: 100%; overflow-x: auto; }
        th, td { padding: 6px 13px; border: 1px solid -apple-system-separator; }
        th { font-weight: 600; }
        tr:nth-child(2n) td { background: rgba(128, 128, 128, 0.06); }
        """

    /// One class per scope with the editor's own colours, so a snippet looks the same in both modes.
    private static let syntax: String = {
        var light = ""
        var dark = ""
        for raw in 1...SyntaxScope.deletion.rawValue {
            guard let scope = SyntaxScope(rawValue: raw) else { continue }
            let color = EditorTheme.color(for: scope)
            light += ".s\(raw) { color: \(cssColor(color, in: .aqua)); }\n"
            dark += ".s\(raw) { color: \(cssColor(color, in: .darkAqua)); }\n"
        }
        return "\n\(light)@media (prefers-color-scheme: dark) {\n\(dark)}\n"
    }()

    private static func cssColor(_ color: NSColor, in appearance: NSAppearance.Name) -> String {
        var resolved = color
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        func channel(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return "rgb(\(channel(resolved.redComponent)) \(channel(resolved.greenComponent)) \(channel(resolved.blueComponent)))"
    }
}
