// Manual verification harness for TerminalKit.
//
//   terminal-demo [--command <string>] [--cwd <path>] [--print-events]
//                 [--exit-on-child-exit] [--dump-text-after <seconds>]
//                 [--type <string>] [--quit-after <seconds>] [--hidden] [--no-wait]
//
// --type understands \n, \r, \t, \e and \xHH escapes. --hidden never mounts the
// view, to prove sessions run without a window.

import AppKit
import SwiftUI
import TerminalKit

struct Options {
    var command: String?
    var cwd = FileManager.default.currentDirectoryPath
    var printEvents = false
    var exitOnChildExit = false
    var dumpTextAfter: Double?
    var type: String?
    var quitAfter: Double?
    var hidden = false
    var waitAfterCommand = true
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = args.next() else {
            FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
            exit(2)
        }
        return v
    }
    while let arg = args.next() {
        switch arg {
        case "--command": options.command = value(arg)
        case "--cwd": options.cwd = value(arg)
        case "--print-events": options.printEvents = true
        case "--exit-on-child-exit": options.exitOnChildExit = true
        case "--dump-text-after": options.dumpTextAfter = Double(value(arg))
        case "--type": options.type = unescape(value(arg))
        case "--quit-after": options.quitAfter = Double(value(arg))
        case "--hidden": options.hidden = true
        case "--no-wait": options.waitAfterCommand = false
        default:
            FileHandle.standardError.write(Data("unknown flag \(arg)\n".utf8))
            exit(2)
        }
    }
    return options
}

func unescape(_ s: String) -> String {
    var out = ""
    var chars = Array(s)[...]
    while let c = chars.popFirst() {
        guard c == "\\", let next = chars.popFirst() else {
            out.append(c)
            continue
        }
        switch next {
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "e": out.append("\u{1B}")
        case "x":
            let hex = String(chars.prefix(2))
            chars = chars.dropFirst(2)
            if let value = UInt8(hex, radix: 16) { out.append(Character(UnicodeScalar(value))) }
        default: out.append(next)
        }
    }
    return out
}

func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

func describe(_ event: TerminalEvent) -> String {
    switch event {
    case .titleChanged(let t): "event: titleChanged \(t.debugDescription)"
    case .workingDirectoryChanged(let p): "event: workingDirectoryChanged \(p.debugDescription)"
    case .notification(let title, let body): "event: notification title=\(title.debugDescription) body=\(body.debugDescription)"
    case .bell: "event: bell"
    case .progress(let p): "event: progress \(p.map { "\($0.state) \($0.percent.map(String.init) ?? "-")" } ?? "removed")"
    case .childExited(let code): "event: childExited exitCode=\(code)"
    case .closeRequested: "event: closeRequested"
    case .openLink(let link, let alternate): "event: openLink \(link.url.absoluteString.debugDescription) alternate=\(alternate)"
    }
}

final class DemoDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    var terminalApp: TerminalApp?
    var session: TerminalSession?
    var window: NSWindow?

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let terminalApp = try TerminalApp()
            let session = try terminalApp.makeSession(.init(
                workingDirectory: URL(filePath: options.cwd),
                command: options.command,
                waitAfterCommand: options.waitAfterCommand))
            self.terminalApp = terminalApp
            self.session = session
        } catch {
            emit("error: \(error)")
            exit(1)
        }
        guard let session else { return }
        emit("session started hidden=\(options.hidden)")

        Task { @MainActor [options] in
            for await event in session.events {
                if options.printEvents { emit(describe(event)) }
                if case .openLink(let link, _) = event { link.openExternally() }
                if case .closeRequested = event, !options.waitAfterCommand {
                    session.close()
                    NSApp.terminate(nil)
                }
                if case .childExited = event, options.exitOnChildExit {
                    try? await Task.sleep(for: .milliseconds(300))
                    NSApp.terminate(nil)
                }
            }
        }

        if let delay = options.dumpTextAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    emit("----- visible text begin -----")
                    emit(session.readVisibleText().trimmingCharacters(in: .whitespacesAndNewlines))
                    emit("----- visible text end -----")
                }
            }
        }
        if let text = options.type {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { session.sendText(text) }
            }
        }
        if let delay = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }

        guard !options.hidden else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "terminal-demo"
        window.contentView = NSHostingView(rootView: TerminalView(session: session))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        terminalApp?.setAppFocused(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        terminalApp?.setAppFocused(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.close()
    }
}

func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu()
    appItem.submenu?.addItem(withTitle: "Quit terminal-demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    return main
}

let options = parseOptions()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.mainMenu = makeMainMenu()
let delegate = DemoDelegate(options: options)
app.delegate = delegate
app.run()
