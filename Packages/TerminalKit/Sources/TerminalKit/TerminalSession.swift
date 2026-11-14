import AppKit
import GhosttyKit

/// One terminal surface and its child process.
///
/// The process starts in `TerminalApp.makeSession` and keeps running whether
/// or not `view` is in a window. The session, not the view hierarchy, owns
/// the surface: it lives until `close()` is called or the session is released.
@MainActor
public final class TerminalSession: Identifiable {
    public struct Configuration: Sendable {
        public var workingDirectory: URL
        /// Run through the user's shell. nil starts the user's default login shell.
        public var command: String?
        /// Added to the inherited environment.
        public var environment: [String: String]
        /// Keep the surface open after the command exits so output stays
        /// readable. Ghostty forces this on whenever `command` is set.
        public var waitAfterCommand: Bool

        public init(
            workingDirectory: URL,
            command: String? = nil,
            environment: [String: String] = [:],
            waitAfterCommand: Bool = true
        ) {
            self.workingDirectory = workingDirectory
            self.command = command
            self.environment = environment
            self.waitAfterCommand = waitAfterCommand
        }
    }

    public let id = UUID()

    /// The surface view. It can be moved between superviews at will; mount it
    /// through `TerminalView` or add it to an AppKit hierarchy directly.
    public let view: NSView

    /// Events in the order Ghostty reported them. The stream supports a single
    /// consumer, buffers without limit until read, and finishes on `close()`.
    public let events: AsyncStream<TerminalEvent>

    public private(set) var title: String = ""
    public private(set) var workingDirectory: String?
    public private(set) var hasExited = false

    let key: UInt
    let surfaceView: SurfaceView
    private let app: TerminalApp
    private let continuation: AsyncStream<TerminalEvent>.Continuation
    /// Ghostty's state for a paste awaiting the user's answer. It must be
    /// completed or denied exactly once, including when the session closes.
    private var pendingPaste: UnsafeMutableRawPointer?
    /// Where the command wrapper records the real exit status; see `wrap`.
    private var exitStatusFile: URL?

    var surface: ghostty_surface_t? { surfaceView.surface }

    init(app: TerminalApp, key: UInt) {
        self.app = app
        self.key = key
        // Ghostty sizes its first grid from the view, so it needs a nonzero
        // frame even when the session starts unmounted.
        self.surfaceView = SurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view = surfaceView
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        surfaceView.acceptsDroppedText = { [weak app] text in app?.acceptsDroppedText?(text) ?? true }
    }

    isolated deinit {
        close()
    }

    func start(_ configuration: Configuration) throws {
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(surfaceView).toOpaque()))
        surfaceConfig.userdata = UnsafeMutableRawPointer(bitPattern: key)
        surfaceConfig.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        surfaceConfig.wait_after_command = configuration.waitAfterCommand
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let env = configuration.environment.map { (strdup($0.key)!, strdup($0.value)!) }
        defer {
            for (k, v) in env {
                free(k)
                free(v)
            }
        }
        var cEnv = env.map { ghostty_env_var_s(key: UnsafePointer($0.0), value: UnsafePointer($0.1)) }

        // Ghostty treats an empty command as "default shell"; so do we.
        let command = configuration.command.flatMap { $0.isEmpty ? nil : $0 }.map { command in
            let statusFile = FileManager.default.temporaryDirectory
                .appending(path: "terminalkit-\(UUID().uuidString).status")
            exitStatusFile = statusFile
            return Self.wrap(command, statusFile: statusFile)
        }

        let surface: ghostty_surface_t? = configuration.workingDirectory.path(percentEncoded: false).withCString { cwd in
            surfaceConfig.working_directory = cwd
            return withOptionalCString(command) { command in
                surfaceConfig.command = command
                return cEnv.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = buffer.count
                    return ghostty_surface_new(app.app, &surfaceConfig)
                }
            }
        }
        guard let surface else {
            removeExitStatusFile()
            throw TerminalError.surfaceCreationFailed
        }
        surfaceView.attach(surface)
    }

    /// On macOS Ghostty launches every command through `login(1)`, which
    /// always exits 0, so Ghostty reports 0 whatever the command returned.
    /// The wrapper records the real status in a file from an EXIT trap, which
    /// also covers a bare `exit N` in the command. login only exits after the
    /// wrapper, so the file is complete when Ghostty sees the exit.
    ///
    /// INT and QUIT are caught, not ignored: caught signals reset to default
    /// in the command, so Ctrl-C still reaches it, while the wrapper outlives
    /// a Ctrl-C the command chooses to survive (agents cancel, not quit).
    ///
    /// Ghostty runs the result as `exec -l <string>` in bash. Going through
    /// env keeps the login-shell dash on env's argv[0] instead of making sh a
    /// login shell that would source profile files the bare command never saw.
    private static func wrap(_ command: String, statusFile: URL) -> String {
        let script = """
        __terminalkit_status=\(shellQuote(statusFile.path(percentEncoded: false)))
        trap 'printf %s "$?" > "$__terminalkit_status"' EXIT
        trap : INT QUIT
        \(command)
        """
        return "/usr/bin/env /bin/sh -c \(shellQuote(script))"
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func readExitStatus(fallback: UInt32) -> UInt32 {
        guard let exitStatusFile,
              let text = try? String(contentsOf: exitStatusFile, encoding: .utf8),
              let status = UInt32(text) else { return fallback }
        removeExitStatusFile()
        return status
    }

    private func removeExitStatusFile() {
        guard let exitStatusFile else { return }
        try? FileManager.default.removeItem(at: exitStatusFile)
        self.exitStatusFile = nil
    }

    public func setOccluded(_ occluded: Bool) {
        surfaceView.setHostOccluded(occluded)
    }

    /// Makes the view first responder. Does nothing while it is not in a window.
    public func focus() {
        guard let window = surfaceView.window else { return }
        window.makeFirstResponder(surfaceView)
    }

    /// Sends text to the child with paste semantics: bracketed paste is applied
    /// when the program enabled it, and "\n" arrives as a carriage return.
    public func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { chars in
                ghostty_surface_text(surface, chars.baseAddress, UInt(chars.count))
            }
        }
    }

    /// Pastes `text` as if it came from the clipboard. Unlike `sendText`,
    /// Ghostty's paste protection applies, so text that would run commands in
    /// a shell is confirmed first.
    public func paste(_ text: String) {
        surfaceView.paste(text)
    }

    /// Pastes the paths shell-escaped and space-separated, exactly what
    /// dropping the same files on the terminal produces.
    public func pasteFileURLs(_ urls: [URL]) {
        surfaceView.paste(SurfaceView.droppedText(forFiles: urls))
    }

    /// The text currently in the viewport (not the scrollback). If the user scrolled back, this is
    /// the older text they are looking at, not what the program last drew.
    public func readVisibleText() -> String {
        readText(GHOSTTY_POINT_VIEWPORT) ?? ""
    }

    /// The bottom of the live grid, the rows the program is drawing into right now, wherever the
    /// user has scrolled. Anything deciding which key to press has to look here: the viewport can
    /// show an old, already answered prompt. Nil when the surface is gone or the read fails, so
    /// callers can tell "nothing there" from "could not look".
    public func readActiveScreenText() -> String? {
        readText(GHOSTTY_POINT_ACTIVE)
    }

    private func readText(_ area: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: area, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: area, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        // An empty grid reads back as no buffer; that is a successful read of nothing.
        guard let ptr = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Frees the surface, which hangs up the child's pty. Safe to call twice.
    public func close() {
        guard let surface else { return }
        if let pendingPaste {
            self.pendingPaste = nil
            ghostty_surface_deny_clipboard_request(surface, pendingPaste)
        }
        app.unregister(key)
        surfaceView.detach()
        ghostty_surface_free(surface)
        removeExitStatusFile()
        hasExited = true
        continuation.finish()
    }

    func emit(_ event: TerminalEvent) {
        var event = event
        switch event {
        case .titleChanged(let title): self.title = title
        case .workingDirectoryChanged(let pwd): workingDirectory = pwd
        case .childExited(let code):
            hasExited = true
            event = .childExited(exitCode: readExitStatus(fallback: code))
        default: break
        }
        continuation.yield(event)
    }

    /// Ghostty's paste protection flagged the clipboard (for example it
    /// contains a newline that would run a command). Ask before pasting.
    func requestPasteConfirmation(contents: [ClipboardContent], available: [String], state: UnsafeMutableRawPointer?) {
        if let previous = pendingPaste, let surface {
            ghostty_surface_deny_clipboard_request(surface, previous)
        }
        pendingPaste = state

        let alert = NSAlert()
        alert.messageText = "Paste into the terminal?"
        alert.informativeText = "The clipboard looks like it may run commands when pasted.\n\n"
            + (contents.first { $0.mime == "text/plain" }.flatMap { String(data: $0.data, encoding: .utf8) }?
                .prefix(1_000).description ?? "")
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")

        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            // The session may have closed, or a newer paste replaced this one,
            // while the alert was up; Ghostty's state is then already resolved.
            guard let self, let surface = self.surface, let pending = self.pendingPaste, pending == state else { return }
            self.pendingPaste = nil
            if response == .alertFirstButtonReturn {
                TerminalApp.completeClipboardRequest(
                    surface, contents: contents, available: available, state: pending, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, pending)
            }
        }

        // Deferred so no modal loop runs inside the libghostty callback.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let window = self?.surfaceView.window {
                    alert.beginSheetModal(for: window) { response in
                        MainActor.assumeIsolated { finish(response) }
                    }
                } else {
                    finish(alert.runModal())
                }
            }
        }
    }
}

private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let string else { return body(nil) }
    return string.withCString(body)
}
