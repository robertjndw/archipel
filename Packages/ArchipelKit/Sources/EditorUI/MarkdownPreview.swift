import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Renders the buffer, not the file, so unsaved edits show too. Renders again whenever the file
/// changes on disk.
struct MarkdownPreview: View {
    let buffer: TextBuffer
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
            let model = model ?? MarkdownPreviewModel(fileURL: buffer.fileURL, onOpenLink: onOpenLink)
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
    private var isReady = false
    private var shown: String?
    private var latest: String?

    init(fileURL: URL, onOpenLink: @escaping (URL) -> Void) {
        let baseURL = PreviewScheme.url(for: fileURL)
        var configuration = WebPage.Configuration()
        // The Markdown's own HTML can carry scripts. Ours run anyway: this only stops the page's.
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        // Relative image and link paths resolve against the file and are served from disk here.
        // A file URL as the base would only reach the file's own folder, not `../images`.
        if let scheme = URLScheme(PreviewScheme.name) {
            configuration.urlSchemeHandlers[scheme] = PreviewScheme.Handler()
        }
        page = WebPage(configuration: configuration, navigationDecider: LinkDecider(documentURL: baseURL, onOpenLink: onOpenLink))
        Task { [weak self] in
            guard let self else { return }
            do {
                for try await _ in page.load(html: Self.document, baseURL: baseURL) {}
            } catch {
                return
            }
            isReady = true
            if let latest { await push(latest) }
        }
    }

    func show(_ html: String) async {
        latest = html
        guard isReady else { return }
        await push(html)
    }

    private func push(_ html: String) async {
        guard html != shown else { return }
        shown = html
        _ = try? await page.callJavaScript("document.getElementById('content').innerHTML = html", arguments: ["html": html])
    }

    private static let document = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(MarkdownStyle.css)</style>
        </head>
        <body><article id="content"></article></body>
        </html>
        """
}

/// Opens links the way the rest of the app does instead of navigating the preview away. Anchors
/// within the document still scroll.
private struct LinkDecider: WebPage.NavigationDeciding {
    let documentURL: URL
    let onOpenLink: (URL) -> Void

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        if url.scheme == PreviewScheme.name {
            let file = PreviewScheme.fileURL(for: url)
            if file == PreviewScheme.fileURL(for: documentURL), url.fragment != nil { return .allow }
            onOpenLink(file)
        } else {
            onOpenLink(url)
        }
        return .cancel
    }
}

/// `archipel-preview://local/<absolute path>` stands for that file on disk.
private enum PreviewScheme {
    static let name = "archipel-preview"

    static func url(for fileURL: URL) -> URL {
        URL(string: "\(name)://local")!.appending(path: fileURL.path(percentEncoded: false))
    }

    static func fileURL(for url: URL) -> URL {
        URL(filePath: url.path(percentEncoded: false))
    }

    struct Handler: URLSchemeHandler {
        func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
            AsyncThrowingStream { continuation in
                guard let url = request.url else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }
                Task.detached {
                    do {
                        let data = try Data(contentsOf: PreviewScheme.fileURL(for: url))
                        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        let response = URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil)
                        continuation.yield(.response(response))
                        continuation.yield(.data(data))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
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
