// Adapted from Ghostty's macOS app (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift,
// Ghostty.Input.swift, NSEvent+Extension.swift and Helpers/KeyboardLayout.swift).
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License,
// see THIRD_PARTY_NOTICES.md.

import AppKit
import Carbon
import GhosttyKit

/// The NSView a Ghostty surface renders into. Ghostty installs its own Metal
/// layer on it during ghostty_surface_new. Every input path is a no-op once
/// the owning session has freed the surface.
final class SurfaceView: NSView, @MainActor NSTextInputClient {
    private(set) var surface: ghostty_surface_t?

    private var focused = false
    private var hostOccluded = false
    private var reportedVisible: Bool?
    private var cursor: NSCursor = .iBeam
    private var prevPressureStage = 0
    private var keyUpMonitor: Any?

    private var markedText = NSMutableAttributedString()
    /// Non-nil only while keyDown runs interpretKeyEvents; collects insertText calls.
    private var keyTextAccumulator: [String]?
    private var leadSurrogate: UTF16Char?

    /// Timestamp of a Cmd/Ctrl event that performKeyEquivalent let AppKit try
    /// first. If AppKit bounces the same event back through doCommand, it is
    /// resent so keyDown can encode it. Timestamps are the only identity that
    /// survives the round trip; synthetic events have 0 and are skipped.
    private var lastPerformKeyEvent: TimeInterval?

    /// Consulted before pasting plain text dropped on the view; see `TerminalApp.acceptsDroppedText`.
    var acceptsDroppedText: (String) -> Bool = { _ in true }
    /// Drawn over the terminal while a drop is hovering; created on first use.
    var dropHighlightLayer: CALayer?

    override var acceptsFirstResponder: Bool { true }

    isolated deinit {
        // A window torn down with us still inside never sends viewWillMove.
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
    }

    func attach(_ surface: ghostty_surface_t) {
        self.surface = surface
        // A new core surface starts out believing it is focused and visible.
        focused = true
        setFocused(false)
        updateContentScale()
        updateSurfaceSize()
        updateDisplayID()
        syncOcclusion()
        syncFocus()
        registerForDraggedTypes(Self.droppedTypes)
    }

    func detach() {
        surface = nil
        unregisterDraggedTypes()
    }

    func setHostOccluded(_ occluded: Bool) {
        hostOccluded = occluded
        syncOcclusion()
    }

    // MARK: Window, focus, visibility

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: nil, object: window)
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                center.addObserver(self, selector: #selector(windowStateChanged), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(windowScreenChanged), name: NSWindow.didChangeScreenNotification, object: window)

            // AppKit never delivers keyUp for Command-modified keys through the
            // responder chain; Ghostty needs releases for kitty keyboard mode.
            keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.focused, event.modifierFlags.contains(.command) else { return false }
                    self.keyUp(with: event)
                    return true
                }
                return consumed ? nil : event
            }
        }
        updateDisplayID()
        syncFocus()
        syncOcclusion()
    }

    @objc private func windowStateChanged() {
        syncFocus()
        syncOcclusion()
    }

    @objc private func windowScreenChanged() {
        updateDisplayID()
        viewDidChangeBackingProperties()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocused(window?.isKeyWindow ?? false) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func syncFocus() {
        setFocused(window?.isKeyWindow == true && window?.firstResponder === self)
    }

    private func setFocused(_ focused: Bool) {
        guard let surface, focused != self.focused else { return }
        self.focused = focused
        ghostty_surface_set_focus(surface, focused)
    }

    /// Ghostty stops rendering, but keeps the pty and parser running, while
    /// the surface is reported invisible. Unmounted views count as invisible.
    private func syncOcclusion() {
        guard let surface else { return }
        let visible = !hostOccluded && (window?.occlusionState.contains(.visible) ?? false)
        guard visible != reportedVisible else { return }
        reportedVisible = visible
        ghostty_surface_set_occlusion(surface, visible)
    }

    private func updateDisplayID() {
        guard let surface,
              let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        // Drives the CVDisplayLink Ghostty uses for vsync on this screen.
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    // MARK: Size and scale

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            // We render at backing resolution ourselves; a mismatched
            // contentsScale makes the compositor scale the layer again.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateContentScale()
        updateSurfaceSize()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func updateContentScale() {
        guard let surface else { return }
        ghostty_surface_set_content_scale(surface, backingScale, backingScale)
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scale = backingScale
        let width = (bounds.width * scale).rounded(.down)
        let height = (bounds.height * scale).rounded(.down)
        // SwiftUI can lay a view out at zero size transiently; Ghostty would
        // reflow the whole screen into a zero-column grid.
        guard width >= 1, height >= 1 else { return }
        ghostty_surface_set_size(surface, UInt32(width), UInt32(height))
    }

    // MARK: Cursor

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let newCursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: newCursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: newCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: newCursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: newCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: newCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: newCursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: newCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: newCursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: newCursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: newCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: newCursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: newCursor = .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: newCursor = .resizeRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: newCursor = .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: newCursor = .resizeDown
        default: return
        }
        guard newCursor != cursor else { return }
        cursor = newCursor
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        // activeAlways: TUIs with mouse reporting still want motion while the
        // window is not key.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        prevPressureStage = 0
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_PRESS, Self.mouseButton(event.buttonNumber), event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, Self.mouseButton(event.buttonNumber), event)
    }

    @discardableResult
    private func sendMouseButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    private static func mouseButton(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3...10: ghostty_input_mouse_button_e(UInt32(GHOSTTY_MOUSE_FOUR.rawValue) + UInt32(number - 3))
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Ghostty decides whether to emit mouse reports from the last known
        // position, which mouseExited set to (-1, -1).
        sendMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // While dragging we keep getting mouseDragged outside the view.
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Ghostty's origin is top-left.
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // Upstream's tuning: trackpad deltas feel sluggish at 1x.
            x *= 2
            y *= 2
        }
        // Packed ScrollMods: bit 0 precision, bits 1-3 momentum phase.
        let momentum: Int32 = switch event.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        let mods: ghostty_input_scroll_mods_t = (precise ? 1 : 0) | (momentum << 1)
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        prevPressureStage = event.stage
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Options like macos-option-as-alt remove modifiers from translation
        // only. Rebuild the event with those flags, but keep every other bit:
        // hidden device bits matter for some dead keys.
        let translationGhosttyMods = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhosttyMods.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }
        // The original event object must be reused when nothing changed:
        // Korean IMEs break if they receive an equal-but-new event.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        // Keys that switch input source (e.g. Ctrl-Space) must not reach the terminal.
        let keyboardIdBefore = markedTextBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardIdBefore != Self.keyboardLayoutID {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        // Also composing when preedit just ended: e.g. backspace that cancels
        // a Japanese composition must not delete text before it.
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            // The IME committed text while handling a key that is not itself
            // input. Send the text, then only replay keys that still matter.
            for text in list where !Self.isComposingControlInput(text, composing: composing) {
                sendCommittedText(action, text)
            }
            if Self.shouldReplayAfterCommit(translationEvent) {
                sendKey(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControlInput(text, composing: composing) {
                sendKey(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.isComposingControlInput(event.characters, composing: composing) { return }
            sendKey(action, event: event, translationEvent: translationEvent,
                    text: Self.ghosttyCharacters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        let mods = Self.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // The modifier is still down, but it may be the other side that
            // is held; only a press if this key's side is the one down.
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        sendKey(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers key equivalents to every view in the window, not just
        // the first responder.
        guard event.type == .keyDown, focused, let surface else { return false }

        var flags = ghostty_binding_flags_e(0)
        var keyEvent = Self.keyEvent(event, GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        if isBinding {
            // Ghostty's defaults bind Cmd-T, Cmd-W, Cmd-N and friends to tab and
            // window actions we do not implement. Let the host's menu claim a
            // shortcut first so those keep working; `all`/`performable`
            // bindings are Ghostty's to decide, as upstream does.
            let raw = flags.rawValue
            if raw & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue != 0,
               raw & (GHOSTTY_BINDING_FLAGS_ALL.rawValue | GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) == 0,
               NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Ctrl-Return would otherwise open the context menu.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // Ctrl-/ beeps in AppKit; terminals expect it as Ctrl-_.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }
        keyDown(with: finalEvent)
        return true
    }

    override func doCommand(by selector: Selector) {
        // Overridden so unhandled commands do not beep. If this is the event
        // performKeyEquivalent declined, send it back through to keyDown.
        if let lastPerformKeyEvent, let current = NSApp.currentEvent, lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) {
        guard let surface else { return }
        var keyEvent = Self.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing
        // Ghostty encodes control characters itself from keycode + mods, which
        // keeps them distinguishable for the kitty keyboard protocol.
        if let text, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    /// IME commits and dictation are sent as key events with no physical key
    /// so programs treat them as typing, never as a paste.
    private func sendCommittedText(_ action: ghostty_input_action_e, _ text: String) {
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { ptr in
            keyEvent.text = ptr
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let utf8 = Array(markedText.string.utf8)
            utf8.withUnsafeBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) { chars in
                    ghostty_surface_preedit(surface, chars.baseAddress, UInt(chars.count))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Menu actions

    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBinding("select_all") }

    private func performBinding(_ action: String) {
        guard let surface else { return }
        if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
            logger.warning("binding action failed: \(action, privacy: .public)")
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange(location: NSNotFound, length: 0) }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        // Outside keyDown (e.g. switching layouts mid dead-key) nothing else
        // will push the preedit, so do it now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // AppKit asks for odd ranges; the selection is the only text we can
        // meaningfully return, as upstream does.
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        return NSAttributedString(string: String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        let size = ghostty_surface_size(surface)
        let cellWidth = Double(size.cell_width_px) / Double(backingScale)
        let cellHeight = Double(size.cell_height_px) / Double(backingScale)
        var x = 0.0, y = 0.0, width = cellWidth, height = cellHeight
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            // A zero-width rect places the dictation indicator at the caret.
            width = 0
            x += cellWidth * Double(range.location)
        }
        let viewRect = NSRect(x: x, y: bounds.height - y, width: width, height: max(height, cellHeight))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        var chars: String
        switch string {
        case let value as NSAttributedString:
            chars = value.string
        case let value as String:
            chars = value
        default:
            return
        }

        // Some input methods deliver an astral character as two separate
        // surrogate halves; join them like Terminal.app does.
        let utf16 = Array(chars.utf16)
        if utf16.count == 1, UTF16.isLeadSurrogate(utf16[0]) {
            leadSurrogate = utf16[0]
            chars = ""
        } else if utf16.count == 1, UTF16.isTrailSurrogate(utf16[0]) {
            chars = leadSurrogate.map { String(decoding: [$0, utf16[0]], as: UTF16.self) } ?? ""
            leadSurrogate = nil
        } else {
            leadSurrogate = nil
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        if !chars.isEmpty {
            sendCommittedText(GHOSTTY_ACTION_PRESS, chars)
        }
    }

    // MARK: Helpers

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// `text` and `composing` are left for the caller, which controls the C
    /// string's lifetime.
    private static func keyEvent(
        _ event: NSEvent,
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = mods(event.modifierFlags)
        // macOS cannot say which modifiers produced the text. Upstream's
        // long-standing heuristic: control and command never do.
        keyEvent.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }
        return keyEvent
    }

    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first {
            // Control characters are re-derived without Ctrl so Ghostty's
            // encoder sees the base key.
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // AppKit's private-use function key range (arrows, F-keys).
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    /// A lone C0 control character during composition belongs to the IME.
    private static func isComposingControlInput(_ text: String?, composing: Bool) -> Bool {
        guard composing, let scalars = text?.unicodeScalars, scalars.count == 1, let scalar = scalars.first else { return false }
        return scalar.value < 0x20
    }

    private static func shouldReplayAfterCommit(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: // down, right, up
            return true
        case 0x7B: // left: Korean IMEs already leave the caret in place
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }

    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }
}
