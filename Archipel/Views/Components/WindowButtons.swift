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

    /// AppKit lays the buttons out again whenever it rebuilds the title bar: on resizes, on leaving
    /// full screen, on a move to a display with another scale, and at times without any frame
    /// notification at all. So besides those occasions this checks after every window update, the
    /// last step of each event before the window draws, which catches a reset before it is seen.
    /// The check is a comparison of two points. Moving all three buttons by the same distance
    /// keeps AppKit's spacing between them and makes a second pass a no-op, so the frame change
    /// that the move itself causes ends right there.
    final class Anchor: NSView {
        var center: CGFloat = 16 {
            didSet { if center != oldValue { place() } }
        }
        var onMetricsChange: ((WindowMetrics) -> Void)?
        private var reported = WindowMetrics()
        private var observers: [NSObjectProtocol] = []

        // It sits behind the window's content and must never take a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
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
            if let close = window.standardWindowButton(.closeButton) {
                close.postsFrameChangedNotifications = true
                observers.append(notifications.addObserver(forName: NSView.frameDidChangeNotification, object: close, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            place()
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        private func place() {
            guard let window else { return }
            report(for: window)
            // In full screen the buttons live in the menu bar's drop-down title bar, which has a
            // layout of its own.
            guard !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let superview = close.superview else { return }
            let current = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
            let target = NSPoint(x: center, y: window.frame.height - center)
            let dx = target.x - current.x
            var dy = target.y - current.y
            guard abs(dx) >= 0.5 || abs(dy) >= 0.5 else { return }
            if superview.isFlipped { dy = -dy }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            for button in buttons {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x + dx, y: button.frame.origin.y + dy))
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
