import AppKit
import SwiftUI

/// Where the close, minimize and zoom buttons go. The window has no toolbar, so AppKit centers them
/// 16pt from the top and from the leading edge, which is not where the tab rows have their middle.
/// Every toolbar style puts them somewhere else again (20pt compact, 26pt unified), and a toolbar
/// would also lay its own view over the tab rows. So the buttons are moved instead.
enum WindowButtons {
    /// The middle of the top line of the window: the tab rows, the sidebar header and the
    /// inspector's tab switcher. Below a card's top gap in the comfortable pane style.
    static func center(for style: AppSettings.PaneStyle) -> CGFloat {
        topInset(for: style) + PaneTabBar.height / 2
    }

    /// How far the top line sits below the window's top edge: the cards' gap, if they have one.
    static func topInset(for style: AppSettings.PaneStyle) -> CGFloat {
        Chrome.paneGap(for: style)
    }

    /// Where content next to the buttons may start, from the window's leading edge. AppKit's own
    /// layout ends the zoom button 53pt right of the close button's center, and the sidebar used to
    /// keep 9pt clear of it, which with the default 16pt center made the 78pt it reserved.
    static func trailingEdge(for style: AppSettings.PaneStyle) -> CGFloat {
        center(for: style) + 62
    }
}

/// What the window itself tells the views inside it.
struct WindowMetrics: Equatable {
    var isFullScreen = false
    /// The radius of the window's corners as AppKit reports it. 16pt is what macOS 27 reports for
    /// a titled window without a toolbar; it stands in until the window is on screen.
    var cornerRadius: CGFloat = 16
}

extension NSWindow {
    /// The radius of the window's corners as AppKit reports it, nil before it has one.
    var cornerRadius: CGFloat? {
        guard let radius = contentView?.effectiveCornerRadii?.topLeft, radius > 0 else { return nil }
        return radius
    }
}

extension EnvironmentValues {
    /// False in full screen, where the window buttons are hidden and need no room.
    @Entry var showsWindowButtons = true
    /// The radius of the window's corners, for shapes that nest inside them.
    @Entry var windowCornerRadius: CGFloat = 16
}

extension View {
    /// Puts the window buttons' close button at `center` from the window's top and leading edges,
    /// the other two following at AppKit's spacing, and reports what the window looks like.
    func windowButtons(center: CGFloat, metrics: Binding<WindowMetrics>) -> some View {
        background { WindowButtonPlacement(center: center, metrics: metrics) }
    }
}

private struct WindowButtonPlacement: NSViewRepresentable {
    let center: CGFloat
    @Binding var metrics: WindowMetrics

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.onMetricsChange = { metrics = $0 }
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.onMetricsChange = { metrics = $0 }
        view.center = center
    }

    /// AppKit puts the buttons back whenever it lays out the title bar: on resizes, on leaving full
    /// screen, on a move to a display with another scale, and every time the window's title
    /// changes, which is every switch of worktree or island. A title set by SwiftUI changes at the
    /// end of the run loop pass, after the window update of that event, so a check on window
    /// updates alone leaves the buttons in AppKit's place until the next event comes along.
    ///
    /// So each button reports when its frame changes, which asks for a layout of this view, and
    /// the layout moves the buttons. That is still inside the pass in which AppKit laid them out
    /// and before anything is drawn. Moving a button right in its frame change does not last:
    /// AppKit is in the middle of setting that frame then and writes its own value again after.
    ///
    /// The window notifications stay as a fallback, for a layout that changes no frame AppKit
    /// reports. Every check only compares points and is a no-op once the buttons are in place, so
    /// the frame changes that the moves themselves cause end right there.
    final class Anchor: NSView {
        var center: CGFloat = 16 {
            didSet { if center != oldValue { place() } }
        }
        var onMetricsChange: ((WindowMetrics) -> Void)?
        private var reported = WindowMetrics()
        private var observers: [NSObjectProtocol] = []
        /// Where AppKit last put each button, and where this view moved it from there. A button
        /// found anywhere else than where it was moved to has been laid out by AppKit again.
        private var positions: [NSWindow.ButtonType: (appKit: NSPoint, moved: NSPoint)] = [:]

        private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        // It sits behind the window's content and must never take a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            positions = [:]
            guard let window else { return }
            let notifications = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification,
                NSWindow.didUpdateNotification,
            ]
            for name in names {
                observers.append(notifications.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            for button in Self.buttons.compactMap({ window.standardWindowButton($0) }) {
                button.postsFrameChangedNotifications = true
                // No queue: the layout has to be asked for while AppKit is still at it.
                observers.append(notifications.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.needsLayout = true }
                })
            }
            place()
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func layout() {
            super.layout()
            place()
        }

        private func place() {
            guard let window else { return }
            report(for: window)
            // In full screen the buttons live in the menu bar's drop-down title bar, which has a
            // layout of its own.
            guard !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let superview = close.superview else { return }

            for type in Self.buttons {
                guard let button = window.standardWindowButton(type) else { continue }
                let origin = button.frame.origin
                if positions[type].map({ !origin.isClose(to: $0.moved) }) ?? true {
                    positions[type] = (appKit: origin, moved: origin)
                }
            }
            // All three move by what brings the close button's middle to `center` from the
            // window's top and leading edges, which keeps AppKit's spacing between them.
            guard let closePosition = positions[.closeButton] else { return }
            let target = superview.convert(NSPoint(x: center, y: window.frame.height - center), from: nil)
            let dx = target.x - (closePosition.appKit.x + close.frame.width / 2)
            let dy = target.y - (closePosition.appKit.y + close.frame.height / 2)

            for type in Self.buttons {
                guard let button = window.standardWindowButton(type), let position = positions[type] else { continue }
                let moved = NSPoint(x: position.appKit.x + dx, y: position.appKit.y + dy)
                guard !button.frame.origin.isClose(to: moved) else { continue }
                positions[type] = (appKit: position.appKit, moved: moved)
                button.setFrameOrigin(moved)
            }
        }

        private func report(for window: NSWindow) {
            var metrics = reported
            metrics.isFullScreen = window.styleMask.contains(.fullScreen)
            // A window in full screen has square corners; the panes keep the radius they had, so
            // they do not change shape on the way in and out.
            if !metrics.isFullScreen, let radius = window.cornerRadius {
                metrics.cornerRadius = radius
            }
            guard metrics != reported else { return }
            reported = metrics
            // Called from inside SwiftUI's own update when the center changes; state may only
            // change after it.
            DispatchQueue.main.async { [weak self] in self?.onMetricsChange?(metrics) }
        }
    }
}

extension NSPoint {
    fileprivate func isClose(to other: NSPoint) -> Bool {
        abs(x - other.x) < 0.01 && abs(y - other.y) < 0.01
    }
}
