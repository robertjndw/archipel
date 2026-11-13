// Opens a FileEditor or DiffViewer in a window, for checking them by eye outside the app.
//
//   editor-demo file <path> [--type TEXT] [--save] [--external TEXT]
//   editor-demo diff <repository> <relative path> [--staged] [--inline]
//
// Options: --dark / --light force an appearance, --size WIDTHxHEIGHT sets the window size,
// --scroll FRACTION scrolls the first scroll view to that fraction of its height after loading.
// --type inserts TEXT at the end of the first line through the text view, as typing would;
// --save then sends saveDocument: and prints the file; --external appends TEXT to the file on disk
// afterwards, to show the conflict bar for a dirty buffer.
// The window number is printed as "WINDOW <n>" so `screencapture -l <n>` can grab it.

import AppKit
import EditorUI
import SwiftUI

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

@MainActor func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

let dark = option("--dark")
let light = option("--light")
let staged = option("--staged")
let debug = option("--debug")
let inline = option("--inline")
let size = value("--size").flatMap { text -> NSSize? in
    let parts = text.split(separator: "x").compactMap { Double($0) }
    return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
} ?? NSSize(width: 1100, height: 700)
let scrollFraction = value("--scroll").flatMap(Double.init)
let typed = value("--type")
let external = value("--external")
let saves = option("--save")
let store = FileDocumentStore()

let content: AnyView
switch arguments.first {
case "file" where arguments.count == 2:
    content = AnyView(FileEditor(url: URL(filePath: arguments[1]), store: store))
case "diff" where arguments.count == 3:
    if inline { UserDefaults.standard.set("inline", forKey: "EditorUI.diffPresentation") } else {
        UserDefaults.standard.set("sideBySide", forKey: "EditorUI.diffPresentation")
    }
    content = AnyView(DiffViewer(root: URL(filePath: arguments[1], directoryHint: .isDirectory), path: arguments[2], staged: staged))
default:
    FileHandle.standardError.write(Data("usage: editor-demo file <path> | diff <repository> <path> [--staged] [--inline]\n".utf8))
    exit(2)
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "editor-demo"
        if dark { window.appearance = NSAppearance(named: .darkAqua) }
        if light { window.appearance = NSAppearance(named: .aqua) }
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        print("WINDOW \(window.windowNumber)")
        fflush(stdout)

        if debug {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for scrollView in Self.scrollViews(in: window.contentView) {
                    print("ruler", scrollView.verticalRulerView?.frame ?? .zero, scrollView.verticalRulerView?.ruleThickness ?? 0, "requiredThickness", scrollView.verticalRulerView?.requiredThickness ?? 0, "clipframe", scrollView.contentView.frame); print("scroll", scrollView.frame, "doc", scrollView.documentView?.frame ?? .zero, "clip", scrollView.contentView.bounds)
                    if let text = scrollView.documentView as? NSTextView, let lm = text.layoutManager {
                        print("text length", text.string.utf16.count, "container", text.textContainer?.size ?? .zero, "inset", text.textContainerInset)
                        for glyph in [0, 18, 19, 40] where glyph < lm.numberOfGlyphs {
                            print("glyph", glyph, lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil), lm.location(forGlyphAt: glyph))
                        }
                        print("color", text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) ?? "nil", "font", text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) ?? "nil")
                    }
                }
                fflush(stdout)
            }
        }
        if typed != nil || saves || external != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.exerciseEditing(in: window) }
        }
        if let scrollFraction {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let scrollView = Self.scrollViews(in: window.contentView).last,
                      let document = scrollView.documentView else { return }
                let y = (document.frame.height - scrollView.contentView.bounds.height) * scrollFraction
                document.scroll(NSPoint(x: scrollView.contentView.bounds.minX, y: max(0, y)))
            }
        }
    }

    private static func exerciseEditing(in window: NSWindow) {
        guard arguments.first == "file", let textView = textViews(in: window.contentView).first else {
            print("EDIT no text view")
            return
        }
        let url = URL(filePath: arguments[1])
        if let typed {
            let firstLineEnd = (textView.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
            let end = firstLineEnd.length > 0 && textView.string.utf16.count >= NSMaxRange(firstLineEnd)
                ? NSMaxRange(firstLineEnd) - ((textView.string as NSString).substring(with: firstLineEnd).hasSuffix("\n") ? 1 : 0)
                : 0
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.insertText(typed, replacementRange: textView.selectedRange())
            print("EDIT typed, dirty:", store.isDirty(url), "undo:", textView.undoManager?.canUndo ?? false)
        }
        if saves {
            // The same route the app's File > Save menu item takes: nil target, first responder chain.
            let handled = NSApp.sendAction(NSSelectorFromString("saveDocument:"), to: nil, from: nil)
            print("EDIT saveDocument handled:", handled)
            print("EDIT saved, dirty:", store.isDirty(url))
            if let data = try? Data(contentsOf: url) {
                print("EDIT bytes:", data.prefix(80).map { String(format: "%02x", $0) }.joined(separator: " "))
                print("EDIT text:", String(decoding: data.prefix(200), as: UTF8.self).debugDescription)
            }
            if let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int {
                print("EDIT permissions:", String(permissions, radix: 8))
            }
        }
        if let external {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(external.utf8))
                try? handle.close()
            }
            print("EDIT wrote externally")
        }
        fflush(stdout)
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
