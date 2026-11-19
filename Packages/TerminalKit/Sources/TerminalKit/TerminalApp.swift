// Adapted from Ghostty's macOS app (macos/Sources/Ghostty/Ghostty.App.swift and
// Helpers/Extensions/NSPasteboard+Extension.swift).
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License,
// see THIRD_PARTY_NOTICES.md.

import AppKit
import GhosttyKit
import os
import Synchronization
import UniformTypeIdentifiers

let logger = Logger(subsystem: "TerminalKit", category: "terminal")

/// The process-wide Ghostty runtime. Create one, keep it alive for as long as
/// any session exists (sessions also retain it), and call `setAppFocused` from
/// the host's application activation callbacks.
@MainActor
public final class TerminalApp {
    // C callbacks reach the app through this weak static rather than an
    // Unmanaged userdata pointer, so a wakeup that was queued just before the
    // app was freed finds nil instead of a dangling object.
    fileprivate static weak var current: TerminalApp?
    private static var ghosttyInitialized = false

    let app: ghostty_app_t
    private var config: ghostty_config_t
    private var sessions: [UInt: WeakSession] = [:]
    private var nextSessionKey: UInt = 1
    private var colorScheme: ghostty_color_scheme_e?
    private var appearanceObservation: NSKeyValueObservation?
    private var keyboardObserver: (any NSObjectProtocol)?

    /// Asked before plain text dragged onto a terminal is pasted. The host
    /// uses it to turn away its own drags that only carry an identifier,
    /// such as a tab being moved, which would otherwise land in the shell.
    public var acceptsDroppedText: ((String) -> Bool)?

    /// The terminal colors of the user's Ghostty config, for the chrome the host draws around its
    /// terminals. Follows the light or dark theme once the color scheme is known.
    public private(set) var colors: TerminalColors {
        didSet { if colors != oldValue { onColorsChange?(colors) } }
    }
    public var onColorsChange: ((TerminalColors) -> Void)?

    /// Loads the user's Ghostty config files if present so Ghostty users keep
    /// their theme, font and keybindings.
    public init() throws {
        guard Self.current == nil else { throw TerminalError.alreadyInitialized }

        if !Self.ghosttyInitialized {
            // Ghostty scans argv for its own `+action` CLI syntax. Passing only
            // argv[0] keeps the host's flags from ever being interpreted.
            guard ghostty_init(1, CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
                throw TerminalError.initializationFailed
            }
            Self.ghosttyInitialized = true
        }

        guard let config = Self.loadConfig() else { throw TerminalError.configurationFailed }

        var runtime = Self.runtimeConfig()
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw TerminalError.appCreationFailed
        }
        self.app = app
        self.config = config
        colors = TerminalColors(config: config)
        Self.current = self

        ghostty_app_set_focus(app, NSApplication.shared.isActive)

        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
            MainActor.assumeIsolated { TerminalApp.current?.applyAppearance() }
        }

        // Ghostty caches the keyboard layout for key translation and must be
        // told when the user switches input sources.
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let app = TerminalApp.current?.app else { return }
                ghostty_app_keyboard_changed(app)
            }
        }
    }

    /// Built outside the initializer on purpose: closure literals written in a
    /// main-actor context inherit that isolation, and Swift then traps when
    /// Ghostty invokes them from its IO or renderer threads.
    nonisolated private static func runtimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            // macOS has no selection clipboard; declining it means Ghostty
            // never asks us to read or write one.
            supports_selection_clipboard: false,
            wakeup_cb: { _ in scheduleTick() },
            action_cb: { _, target, action in TerminalApp.handleAction(target: target, action: action) },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                TerminalApp.readClipboard(userdata, location, state, mimes, mimesLen, list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                TerminalApp.confirmReadClipboard(userdata, confirm, state, request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                TerminalApp.writeClipboard(userdata, location, content, len, confirm)
            },
            close_surface_cb: { userdata, _ in
                let key = sessionKey(userdata)
                onMain { TerminalApp.current?.session(for: key)?.emit(.closeRequested) }
            }
        )
    }

    isolated deinit {
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        appearanceObservation?.invalidate()
        ghostty_app_free(app)
        ghostty_config_free(config)
    }

    public func makeSession(_ configuration: TerminalSession.Configuration) throws -> TerminalSession {
        let key = nextSessionKey
        nextSessionKey += 1
        let session = TerminalSession(app: self, key: key)
        // Registered before the surface exists because Ghostty may fire
        // surface actions from inside ghostty_surface_new.
        sessions[key] = WeakSession(value: session)
        do {
            try session.start(configuration)
        } catch {
            sessions[key] = nil
            throw error
        }
        if let colorScheme, let surface = session.surface {
            ghostty_surface_set_color_scheme(surface, colorScheme)
        }
        return session
    }

    public func setAppFocused(_ focused: Bool) {
        ghostty_app_set_focus(app, focused)
    }

    func unregister(_ key: UInt) {
        sessions[key] = nil
    }

    fileprivate func session(for key: UInt?) -> TerminalSession? {
        guard let key else { return nil }
        return sessions[key]?.value
    }

    fileprivate func tick() {
        ghostty_app_tick(app)
    }

    private func applyAppearance() {
        let appearance = NSApplication.shared.effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scheme = dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        guard scheme != colorScheme else { return }
        colorScheme = scheme
        // The app-level scheme drives conditional config (`theme = light:X,dark:Y`)
        // for new surfaces; existing surfaces also need it directly so they
        // reload colours and emit DEC 2031 reports.
        ghostty_app_set_color_scheme(app, scheme)
        for session in sessions.values.compactMap(\.value) {
            if let surface = session.surface {
                ghostty_surface_set_color_scheme(surface, scheme)
            }
        }
    }

    private static func loadConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        let count = ghostty_config_diagnostics_count(config)
        for i in 0..<count {
            let diagnostic = ghostty_config_get_diagnostic(config, i)
            if let message = diagnostic.message {
                logger.warning("ghostty config: \(String(cString: message), privacy: .public)")
            }
        }
        return config
    }

    private func reloadConfig(soft: Bool, surface: ghostty_surface_t?) {
        // Soft reloads re-apply the current config so conditional state (the
        // colour scheme) is re-evaluated. Hard reloads re-read the files.
        if soft {
            if let surface {
                ghostty_surface_update_config(surface, config)
            } else {
                ghostty_app_update_config(app, config)
            }
            return
        }
        guard let fresh = Self.loadConfig() else { return }
        if let surface {
            ghostty_surface_update_config(surface, fresh)
            ghostty_config_free(fresh)
        } else {
            ghostty_app_update_config(app, fresh)
            ghostty_config_free(config)
            config = fresh
        }
    }
}

private struct WeakSession {
    weak var value: TerminalSession?
}

// MARK: - Threading helpers

private let tickPending = Atomic<Bool>(false)

/// Ghostty calls wakeup from its IO and renderer threads, sometimes in bursts.
/// One queued main-thread tick drains everything that is pending, so further
/// wakeups are coalesced until that tick starts.
private func scheduleTick() {
    guard !tickPending.exchange(true, ordering: .acquiringAndReleasing) else { return }
    DispatchQueue.main.async {
        // Cleared before ticking so a wakeup raised during the tick schedules another.
        tickPending.store(false, ordering: .releasing)
        MainActor.assumeIsolated { TerminalApp.current?.tick() }
    }
}

private func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}

/// Surface userdata is an integer session key, never an object pointer. A
/// callback that outlives its session then resolves to nil in the registry
/// instead of touching freed memory, and no retain has to be balanced.
private func sessionKey(_ userdata: UnsafeMutableRawPointer?) -> UInt? {
    userdata.map { UInt(bitPattern: $0) }
}

// MARK: - Actions

/// A Ghostty action copied out of C memory, so it can cross to the main thread.
enum RuntimeAction: Sendable {
    case event(TerminalEvent)
    case childExited(UInt32)
    case mouseShape(UInt32)
    case mouseVisible(Bool)
    case openURL(String, kind: UInt32)
    case reloadConfig(soft: Bool)
    case configChanged(TerminalColors)
}

extension TerminalApp {
    nonisolated fileprivate static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard let parsed = parse(action) else { return false }

        var key: UInt?
        var surface: ghostty_surface_t?
        if target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface {
            surface = s
            key = sessionKey(ghostty_surface_userdata(s))
        } else if case .reloadConfig = parsed {
            // One of the two app-targeted actions we act on.
        } else if case .configChanged = parsed {
            // Only the app's config has the light or dark theme applied; a surface's comes from it.
        } else {
            return false
        }

        // In practice Ghostty performs actions from ghostty_app_tick or from
        // input calls, both on the main thread. If that ever changes we still
        // copy and hop rather than touch AppKit off-main; the raw surface
        // pointer is not carried across because it may be freed by then.
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                TerminalApp.current?.perform(parsed, key: key, surface: surface) ?? false
            }
        }
        let sendableKey = key
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let app = TerminalApp.current else { return }
                _ = app.perform(parsed, key: sendableKey, surface: app.session(for: sendableKey)?.surface)
            }
        }
        return true
    }

    nonisolated private static func parse(_ action: ghostty_action_s) -> RuntimeAction? {
        let a = action.action
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = a.set_title.title else { return nil }
            return .event(.titleChanged(String(cString: title)))
        case GHOSTTY_ACTION_PWD:
            guard let pwd = a.pwd.pwd else { return nil }
            return .event(.workingDirectoryChanged(String(cString: pwd)))
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = a.desktop_notification
            return .event(.notification(
                title: n.title.map { String(cString: $0) } ?? "",
                body: n.body.map { String(cString: $0) } ?? ""))
        case GHOSTTY_ACTION_RING_BELL:
            return .event(.bell)
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let p = a.progress_report
            let percent: Int? = p.progress < 0 ? nil : Int(p.progress)
            let progress: TerminalProgress? = switch p.state {
            case GHOSTTY_PROGRESS_STATE_SET: .init(state: .normal, percent: percent)
            case GHOSTTY_PROGRESS_STATE_ERROR: .init(state: .error, percent: percent)
            case GHOSTTY_PROGRESS_STATE_INDETERMINATE: .init(state: .indeterminate, percent: nil)
            case GHOSTTY_PROGRESS_STATE_PAUSE: .init(state: .paused, percent: percent)
            default: nil
            }
            return .event(.progress(progress))
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return .childExited(a.child_exited.exit_code)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return .mouseShape(a.mouse_shape.rawValue)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return .mouseVisible(a.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
        case GHOSTTY_ACTION_OPEN_URL:
            let u = a.open_url
            guard let ptr = u.url else { return nil }
            let bytes = UnsafeRawBufferPointer(start: ptr, count: Int(u.len))
            return .openURL(String(decoding: bytes, as: UTF8.self), kind: u.kind.rawValue)
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return .reloadConfig(soft: a.reload_config.soft)
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Read now: the config only lives for the duration of the callback.
            guard let config = a.config_change.config else { return nil }
            return .configChanged(TerminalColors(config: config))
        default:
            return nil
        }
    }

    private func perform(_ action: RuntimeAction, key: UInt?, surface: ghostty_surface_t?) -> Bool {
        switch action {
        case .reloadConfig(let soft):
            if key != nil, surface == nil { return false }
            reloadConfig(soft: soft, surface: surface)
            return true
        case .openURL(let string, let kind):
            openURL(string, kind: ghostty_action_open_url_kind_e(kind), session: session(for: key))
            // Always claim it: unhandled, Ghostty falls back to spawning `open`
            // on the raw target, bypassing TerminalLink's checks.
            return true
        case .configChanged(let colors):
            guard key == nil else { return false }
            self.colors = colors
            return true
        default:
            break
        }

        guard let session = session(for: key) else { return false }
        switch action {
        case .event(let event):
            session.emit(event)
        case .childExited(let code):
            // Claiming this keeps Ghostty from writing its exit banner into
            // the terminal; for short runs that banner echoes the full
            // wrapped command. The host shows exit state from the event. A
            // key press on the exited surface still yields closeRequested.
            session.emit(.childExited(exitCode: code))
        case .mouseShape(let raw):
            session.surfaceView.setMouseShape(ghostty_action_mouse_shape_e(raw))
        case .mouseVisible(let visible):
            NSCursor.setHiddenUntilMouseMoves(!visible)
        case .openURL, .reloadConfig, .configChanged:
            break
        }
        return true
    }

    private func openURL(_ string: String, kind: ghostty_action_open_url_kind_e, session: TerminalSession?) {
        // Text and HTML kinds are Ghostty's own files, such as its config,
        // not something the terminal printed.
        if kind == GHOSTTY_ACTION_OPEN_URL_KIND_TEXT || kind == GHOSTTY_ACTION_OPEN_URL_KIND_HTML {
            let url = URL(string: string).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(filePath: string)
            if url.isFileURL { NSWorkspace.shared.open(url) }
            return
        }
        guard let link = TerminalLink(string) else {
            logger.info("refusing to open untrusted link target")
            return
        }
        guard let session else {
            link.openExternally()
            return
        }
        // SurfaceView hides ⌥ from Ghostty during ⌘⌥ mouse events. This runs
        // during the click, so the current modifier flags still include it.
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        session.emit(.openLink(link, alternate: flags.contains(.option)))
    }
}

// MARK: - Clipboard

extension TerminalApp {
    nonisolated fileprivate static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?,
        _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        _ mimesLen: Int,
        _ list: Bool
    ) -> ghostty_clipboard_read_result_e {
        // Reads complete synchronously with the surface pointer, which is
        // only known to be alive on the thread Ghostty called us on. Paste
        // bindings and OSC 52 both arrive on the main thread.
        guard Thread.isMainThread, location == GHOSTTY_CLIPBOARD_STANDARD else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        var requested: [String] = []
        if let mimes {
            for i in 0..<mimesLen {
                if let ptr = mimes[i] { requested.append(String(cString: ptr)) }
            }
        }
        let key = sessionKey(userdata)
        // Raw pointers are not Sendable; this only crosses into assumeIsolated
        // on the thread we are already on.
        nonisolated(unsafe) let state = state
        return MainActor.assumeIsolated {
            guard let surface = TerminalApp.current?.session(for: key)?.surface else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
            let pasteboard = NSPasteboard.general
            var contents: [ClipboardContent] = []
            var seen = Set<String>()
            for mime in requested where seen.insert(mime).inserted {
                if let data = pasteboard.terminalData(forMime: mime) {
                    contents.append(ClipboardContent(mime: mime, data: data))
                }
            }
            let available = list ? pasteboard.terminalAvailableMimes() : []
            if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            completeClipboardRequest(surface, contents: contents, available: available, state: state)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }
    }

    nonisolated fileprivate static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        _ state: UnsafeMutableRawPointer?,
        _ request: ghostty_clipboard_request_e
    ) {
        guard Thread.isMainThread else {
            logger.fault("clipboard confirmation off the main thread; request left pending")
            return
        }
        // Copy the borrowed C contents now: the user answers later, and we
        // complete with exactly what they saw rather than re-reading.
        var contents: [ClipboardContent] = []
        var available: [String] = []
        if let c = confirm?.pointee {
            if let ptr = c.contents {
                for i in 0..<c.contents_len {
                    let item = ptr[i]
                    guard let mime = item.mime else { continue }
                    let data = item.len > 0 && item.data != nil ? Data(bytes: item.data, count: item.len) : Data()
                    contents.append(ClipboardContent(mime: String(cString: mime), data: data))
                }
            }
            if let ptr = c.available {
                for i in 0..<c.available_len {
                    if let s = ptr[i] { available.append(String(cString: s)) }
                }
            }
        }
        let key = sessionKey(userdata)
        let isPaste = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE && confirm != nil
        nonisolated(unsafe) let state = state
        MainActor.assumeIsolated {
            guard let session = TerminalApp.current?.session(for: key), let surface = session.surface else { return }
            // Only paste protection gets a prompt. Programs reading the
            // clipboard (OSC 52 / kitty) are refused outright.
            guard isPaste else {
                ghostty_surface_deny_clipboard_request(surface, state)
                return
            }
            session.requestPasteConfirmation(contents: contents, available: available, state: state)
        }
    }

    nonisolated fileprivate static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ len: Int,
        _ confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
        // Writes that Ghostty's policy wants confirmed (OSC 52 with
        // clipboard-write = ask) are dropped: we have no prompt for them.
        guard !confirm else { return }
        var items: [ClipboardContent] = []
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, let data = item.data else { continue }
            items.append(ClipboardContent(mime: String(cString: mime), data: Data(bytes: data, count: item.len)))
        }
        guard !items.isEmpty else { return }
        onMain {
            let pasteboard = NSPasteboard.general
            let typed = items.compactMap { item in
                NSPasteboard.PasteboardType(mimeType: item.mime).map { ($0, item.data) }
            }
            pasteboard.declareTypes(typed.map(\.0), owner: nil)
            for (type, data) in typed {
                pasteboard.setData(data, forType: type)
            }
        }
    }

    static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        contents: [ClipboardContent],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        // Every C buffer must outlive the single call below, so they are
        // allocated up front and released together.
        var allocations: [UnsafeMutableRawPointer] = []
        defer { allocations.forEach { free($0) } }

        func cString(_ s: String) -> UnsafeMutablePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            allocations.append(UnsafeMutableRawPointer(p))
            return p
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = cString(entry.mime), let buffer = malloc(max(entry.data.count, 1)) else { continue }
            allocations.append(buffer)
            entry.data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: entry.data.count)
            cContents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: entry.data.count))
        }
        let cAvailable: [UnsafePointer<CChar>?] = available.compactMap { cString($0).map { UnsafePointer($0) } }

        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }
}

struct ClipboardContent: Sendable {
    let mime: String
    let data: Data
}

extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        if mimeType == "text/plain" {
            self = .string
            return
        }
        guard let type = UTType(mimeType: mimeType) else { return nil }
        self.init(type.identifier)
    }
}

extension NSPasteboard {
    /// "text/plain" prefers copied files as shell-escaped paths, matching
    /// what dropping a file into a terminal produces.
    func terminalData(forMime mime: String) -> Data? {
        switch mime {
        case "text/plain":
            let strings = (pasteboardItems ?? []).compactMap { item -> String? in
                if let plist = item.propertyList(forType: .fileURL),
                   let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
                   url.isFileURL {
                    return Self.shellEscape(url.path)
                }
                return item.string(forType: .string)
            }
            return strings.isEmpty ? nil : Data(strings.joined(separator: " ").utf8)
        default:
            guard let type = PasteboardType(mimeType: mime) else { return nil }
            return data(forType: type)
        }
    }

    /// Declared types only; never reads data, so lazy providers are not asked.
    func terminalAvailableMimes() -> [String] {
        let types = types ?? []
        var result: [String] = []
        if types.contains(.fileURL) || types.contains(.string) {
            result.append("text/plain")
        }
        for type in types {
            guard let mime = UTType(type.rawValue)?.preferredMIMEType,
                  !mime.hasPrefix("text/plain"),
                  !result.contains(mime) else { continue }
            result.append(mime)
        }
        return result
    }

    static func shellEscape(_ string: String) -> String {
        var result = ""
        for char in string {
            if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(char) { result.append("\\") }
            result.append(char)
        }
        return result
    }
}

extension TerminalColors {
    init(config: ghostty_config_t) {
        var background = ghostty_config_color_s()
        _ = Self.get(config, "background", into: &background)
        var fill = background
        // An unset fill reads as false; Ghostty then uses the background, and so do we.
        _ = Self.get(config, "unfocused-split-fill", into: &fill)
        var opacity = 0.7
        _ = Self.get(config, "unfocused-split-opacity", into: &opacity)
        var foreground = ghostty_config_color_s(r: 255, g: 255, b: 255)
        _ = Self.get(config, "foreground", into: &foreground)
        self.init(
            background: RGB(background),
            unfocusedSplitFill: RGB(fill),
            unfocusedSplitOpacity: min(1, max(0.15, opacity)),
            foreground: RGB(foreground)
        )
    }

    private static func get<T>(_ config: ghostty_config_t, _ key: String, into value: inout T) -> Bool {
        withUnsafeMutablePointer(to: &value) { pointer in
            ghostty_config_get(config, pointer, key, UInt(key.utf8.count))
        }
    }
}

private extension TerminalColors.RGB {
    init(_ color: ghostty_config_color_s) {
        self.init(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }
}
