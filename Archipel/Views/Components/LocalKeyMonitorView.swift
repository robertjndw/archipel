import AppKit
import SwiftUI

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

extension View {
    /// A local event monitor that's only installed while `isActive`, usually while hovered, so
    /// there's never more than one around. For input SwiftUI has no gesture for. Return true from
    /// `handle` to swallow the event.
    func localEventMonitor(
        _ mask: NSEvent.EventTypeMask,
        while isActive: Bool,
        handle: @escaping @MainActor (NSEvent) -> Bool
    ) -> some View {
        modifier(LocalEventMonitor(mask: mask, isActive: isActive, handle: handle))
    }
}

private struct LocalEventMonitor: ViewModifier {
    let mask: NSEvent.EventTypeMask
    let isActive: Bool
    let handle: @MainActor (NSEvent) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in watch(active) }
            .onDisappear { watch(false) }
    }

    private func watch(_ on: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard on else { return }
        let handle = handle
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }
}
