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
//
// Review comments (diff only): --review turns commenting on with --targets N fake sessions (default 1);
// --comment SIDE:LINE:TEXT seeds a comment (repeatable). --click X,Y;X,Y clicks window points (top-left
// origin) one after another, in file mode too; --comment-text TEXT types into the open comment popover and presses
// Command-Return, or Escape with --cancel-comment. --shots DIR saves a screenshot of the window and any
// popover after each step; --quit exits after the last one.
// Sending prints the prompt.

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
let review = option("--review")
let targetCount = value("--targets").flatMap(Int.init) ?? 1
var seededComments: [String] = []
while let seeded = value("--comment") { seededComments.append(seeded) }
let clicks = (value("--click") ?? "").split(separator: ";").compactMap(point)
let commentText = value("--comment-text")
let cancelsComment = option("--cancel-comment")
let shotsFolder = value("--shots")
let quits = option("--quit")
let comments = ReviewCommentStore()

func point(_ text: Substring) -> NSPoint? {
    let parts = text.split(separator: ",").compactMap { Double($0) }
    return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
}

let content: AnyView
switch arguments.first {
case "file" where arguments.count == 2:
    content = AnyView(FileEditor(url: URL(filePath: arguments[1]), store: store))
case "diff" where arguments.count == 3:
    if inline { UserDefaults.standard.set("inline", forKey: "EditorUI.diffPresentation") } else {
        UserDefaults.standard.set("sideBySide", forKey: "EditorUI.diffPresentation")
    }
    let root = URL(filePath: arguments[1], directoryHint: .isDirectory)
    if review {
        for seeded in seededComments {
            let parts = seeded.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let line = Int(parts[1]) else { continue }
            comments.add(ReviewComment(path: arguments[2], staged: staged, side: parts[0] == "old" ? .old : .new, line: line, lineText: "(seeded)", body: parts[2]), in: root)
        }
        let targets = [("Claude Code", "sparkle"), ("Codex", "terminal")].prefix(targetCount).map { ReviewTarget(id: UUID(), title: $0.0, symbolName: $0.1) }
        content = AnyView(DiffViewer(root: root, path: arguments[2], staged: staged, comments: comments, targets: targets) { id in
            print("SEND", targets.first { $0.id == id }?.title ?? "?")
            print(ReviewPrompt.text(for: comments.comments(in: root)))
            print("END SEND")
            comments.removeAll(in: root)
            fflush(stdout)
        } onOpenFile: { url in
            print("OPEN", url.path(percentEncoded: false))
            fflush(stdout)
        })
    } else {
        content = AnyView(DiffViewer(root: root, path: arguments[2], staged: staged) { url in
            print("OPEN", url.path(percentEncoded: false))
            fflush(stdout)
        })
    }
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
        if review || !clicks.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.exerciseComments(in: window, step: 0) }
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

    /// One step per call, 1.5 seconds apart so popovers finish animating before the next one.
    private static func exerciseComments(in window: NSWindow, step: Int) {
        var steps: [() -> Void] = []
        for click in clicks {
            steps.append {
                let location = NSPoint(x: click.x, y: window.contentLayoutRect.height - click.y)
                let hit = window.contentView?.hitTest(window.contentView!.convert(location, from: nil))
                for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                    // While another app is frontmost the window is not key, and AppKit would spend the
                    // click on activating it; an AppKit view gets it directly instead.
                    if !window.isKeyWindow, let hit, String(describing: type(of: hit)).hasPrefix("Diff") {
                        kind == .leftMouseDown ? hit.mouseDown(with: event) : hit.mouseUp(with: event)
                    } else {
                        NSApp.sendEvent(event)
                    }
                }
                print("STEP click", click, hit.map { String(describing: type(of: $0)) } ?? "nothing", "windows:", NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) })
            }
        }
        if let commentText {
            steps.append {
                guard let popover = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.firstResponder is NSTextView }),
                      let textView = popover.firstResponder as? NSTextView else {
                    print("STEP no comment popover")
                    return
                }
                textView.insertText(commentText, replacementRange: textView.selectedRange())
                print("STEP typed")
            }
            steps.append {
                guard let popover = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.firstResponder is NSTextView }) else { return }
                let (key, modifiers, code): (String, NSEvent.ModifierFlags, UInt16) = cancelsComment ? ("\u{1b}", [], 53) : ("\r", .command, 36)
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: popover.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                                                isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(event)
                }
                print("STEP", cancelsComment ? "escape" : "command-return")
            }
        }
        guard step <= steps.count else {
            if quits { NSApp.terminate(nil) }
            return
        }
        if step > 0 { steps[step - 1]() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            capture(window, step: step)
            let root = URL(filePath: arguments[1], directoryHint: .isDirectory)
            print("COMMENTS", comments.comments(in: root).map { "\($0.side.rawValue):\($0.line) \($0.lineText.debugDescription) \($0.body.debugDescription)" })
            fflush(stdout)
            exerciseComments(in: window, step: step + 1)
        }
    }

    /// By window number, which works while other apps cover the demo; popovers are windows of their own.
    private static func capture(_ window: NSWindow, step: Int) {
        guard let shotsFolder else { return }
        let windows = [window] + NSApp.windows.filter { $0 !== window && $0.isVisible }
        for (index, shown) in windows.enumerated() {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", "\(shown.windowNumber)", "\(shotsFolder)/step-\(step)-\(index).png"]
            try? process.run()
            process.waitUntilExit()
        }
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
