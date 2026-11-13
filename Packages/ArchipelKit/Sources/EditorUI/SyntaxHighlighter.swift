import Foundation
import Highlighter
import JavaScriptCore
import Synchronization

/// Runs highlight.js (the copy bundled with HighlighterSwift) in a private JavaScriptCore context.
///
/// HighlighterSwift's own API bakes one theme's colours into an attributed string. Going one level
/// lower gives token scopes instead, which map onto dynamic colours that follow light and dark mode
/// without highlighting twice.
final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    /// Larger documents stay plain: highlight.js needs roughly a second per megabyte.
    static let maximumLength = 1_000_000

    // Everything below is only touched on `queue`; a JSContext must not be used from two threads at once.
    private let queue = DispatchQueue(label: "EditorUI.SyntaxHighlighter", qos: .userInitiated)
    private var hljs: JSValue?
    private var loadAttempted = false

    /// Returns nil when the text is too large, the grammar is unknown, or the task was cancelled
    /// while waiting for the shared engine.
    func runs(for text: String, grammar: String) async -> [HighlightRun]? {
        let length = text.utf16.count
        guard length > 0, length <= Self.maximumLength else { return nil }
        let cancelled = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: cancelled.isSet ? nil : self.highlight(text, grammar: grammar, length: length))
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private func highlight(_ text: String, grammar: String, length: Int) -> [HighlightRun]? {
        guard let hljs = loadIfNeeded() else { return nil }
        guard let language = hljs.invokeMethod("getLanguage", withArguments: [grammar]), !language.isUndefined else { return nil }
        let options: [String: Any] = ["language": grammar, "ignoreIllegals": true]
        guard let result = hljs.invokeMethod("highlight", withArguments: [text, options]),
              let html = result.forProperty("value"), html.isString,
              let markup = html.toString() else { return nil }
        let parsed = HighlightHTMLParser.runs(fromHTML: markup)
        // A mismatch would paint colours onto the wrong characters, so plain text is the safer fallback.
        return parsed.length == length ? parsed.runs : nil
    }

    private func loadIfNeeded() -> JSValue? {
        if loadAttempted { return hljs }
        loadAttempted = true
        guard let url = Self.scriptURL(),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        guard let value = context.objectForKeyedSubscript("hljs"), value.isObject else { return nil }
        hljs = value
        return value
    }

    /// SwiftPM names the resource bundle `<package>_<target>.bundle` and places it next to the
    /// executable, inside the app's Resources folder, or beside a test bundle, depending on the host.
    private static func scriptURL() -> URL? {
        let owner = Bundle(for: Highlighter.self)
        let folders = [
            Bundle.main.resourceURL,
            owner.resourceURL,
            Bundle.main.bundleURL,
            owner.bundleURL.deletingLastPathComponent(),
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ].compactMap(\.self)
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix("_Highlighter.bundle") {
                if let url = Bundle(url: folder.appending(path: name))?.url(forResource: "highlight.min", withExtension: "js") {
                    return url
                }
            }
        }
        return nil
    }
}

private final class CancellationFlag: Sendable {
    private let value = Atomic(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}
