import AppKit
import SwiftUI

/// Mounts a session's view. The session outlives any number of mounts; the
/// same NSView moves into whichever TerminalView most recently showed it.
/// Unmounted sessions stop rendering but their processes keep running.
public struct TerminalView: NSViewRepresentable {
    public let session: TerminalSession
    /// Make the terminal first responder once it lands in a window.
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
        self.focusOnMount = focusOnMount
        if self.session !== session {
            unmount()
            self.session = session
        }
        let view = session.view
        guard view.superview !== self else { return }
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
                guard let self, let session = self.session, session.view.superview === self else { return }
                session.focus()
            }
        }
    }
}
