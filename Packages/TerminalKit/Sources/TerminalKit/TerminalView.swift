import AppKit
import SwiftUI

/// Mounts a session's view. The session outlives any number of mounts; the
/// same NSView moves into whichever TerminalView most recently showed it.
/// Unmounted sessions stop rendering but their processes keep running.
public struct TerminalView: NSViewRepresentable {
    public let session: TerminalSession
    /// Make the terminal first responder once it lands in a window, and again whenever this turns
    /// true while it is there, unless a text field is being edited in the window. A host showing
    /// several terminals sets it for one of them.
    public var focusOnMount: Bool

    public init(session: TerminalSession, focusOnMount: Bool = true) {
        self.session = session
        self.focusOnMount = focusOnMount
    }

    public func makeNSView(context: Context) -> NSView {
        let host = TerminalHostView()
        host.mount(session, focusOnMount: focusOnMount)
        return host
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TerminalHostView)?.mount(session, focusOnMount: focusOnMount)
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? TerminalHostView)?.unmount()
    }
}

/// SwiftUI owns this container; the session's view is only ever a guest in
/// it. That keeps SwiftUI from tearing down the surface view itself.
private final class TerminalHostView: NSView {
    private var session: TerminalSession?
    private var focusOnMount = true

    func mount(_ session: TerminalSession, focusOnMount: Bool) {
        let gainedFocus = focusOnMount && !self.focusOnMount
        self.focusOnMount = focusOnMount
        if self.session !== session {
            unmount()
            self.session = session
        }
        let view = session.view
        guard view.superview !== self else {
            // The host's focus came to a terminal that is on screen already: its pane was closed
            // from under the keyboard, or a split was undone. Nothing mounts then, and without
            // this the keys would go nowhere until a click.
            if gainedFocus, window != nil { focusSoon() }
            return
        }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        if window != nil { focusSoon() }
    }

    func unmount() {
        // Another host may already have adopted the view; leave it there.
        if let view = session?.view, view.superview === self {
            view.removeFromSuperview()
        }
        session = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusSoon() }
    }

    private func focusSoon() {
        guard focusOnMount else { return }
        // SwiftUI inserts the host before the window finishes its own
        // responder setup; focusing synchronously can be overridden.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, session.view.superview === self,
                      let window = self.window, !Self.keyboardIsInUse(in: window)
                else { return }
                session.focus()
            }
        }
    }

    /// A session can land in the window long after the user asked for it (it had to launch first),
    /// and by then they may be typing into a text field of the same window. Taking the keyboard
    /// would send the rest of that typing into the terminal. The field editor is only first
    /// responder while a field is being edited.
    ///
    /// A sheet needs no such care: it is a window of its own, and becoming first responder
    /// underneath it is what gives the terminal the keys once the sheet is gone.
    private static func keyboardIsInUse(in window: NSWindow) -> Bool {
        (window.firstResponder as? NSText)?.isFieldEditor == true
    }
}
