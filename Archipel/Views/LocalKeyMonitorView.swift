import AppKit

/// An invisible view that sees its window's key events before the views inside it do, which is the
/// only way to get keys ahead of a terminal that would otherwise swallow them. The monitor is only
/// installed while the view is in a window. Subclasses return true from `handle` to consume an event.
class LocalKeyMonitorView: NSView {
    var eventMask: NSEvent.EventTypeMask { .keyDown }
    private var monitor: Any?

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func handle(_ event: NSEvent) -> Bool { false }
}
