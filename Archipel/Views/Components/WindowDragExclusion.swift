import AppKit
import SwiftUI

extension View {
    /// Stops a drag that starts on this view from moving the window.
    ///
    /// The tab rows sit where the title bar would be, and AppKit still treats that strip as one
    /// even though it's hidden. Clicks get through, but a drag moves the window and SwiftUI's
    /// drag and reorder containers never see it. Adding a gesture to the view doesn't help.
    func blocksWindowDrag() -> some View {
        background { WindowDragExclusion() }
    }
}

private struct WindowDragExclusion: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}

    /// The window server starts a title bar drag on its own, before the app gets the mouse down.
    /// A mouse down monitor is too late, so the window is made immovable as soon as the pointer
    /// is over a marker.
    ///
    /// `decide` checks the pointer against all markers each time instead of counting enters and
    /// exits. A missed exit then can't leave the window stuck.
    final class Marker: NSView {
        private static let markers = NSHashTable<Marker>.weakObjects()

        // Sits behind the tab and must not take its clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // Visible rect only: tabs scrolled out of the row extend under its buttons.
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { Self.decide(for: window) }
        override func mouseExited(with event: NSEvent) { Self.decide(for: window) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            Self.markers.remove(self)
            // A marker removed under the pointer gets no mouseExited.
            Self.decide(for: window)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            Self.markers.add(self)
            Self.decide(for: window)
        }

        private static func decide(for window: NSWindow?) {
            guard let window else { return }
            let pointer = window.mouseLocationOutsideOfEventStream
            window.isMovable = !markers.allObjects.contains { marker in
                marker.window === window && marker.visibleRect.contains(marker.convert(pointer, from: nil))
            }
        }
    }
}
