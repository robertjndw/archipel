import AppKit
import SwiftUI

extension View {
    /// Agents edit files while the user is elsewhere, so coming back to the app is the moment to catch up.
    public func onAppActivation(perform action: @escaping @MainActor () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            action()
        }
    }

    /// Runs `refresh` when the view appears, then every `interval` while it stays on screen and the
    /// app is frontmost, and once more when the app comes back. Polling in the background would
    /// only spawn git and touch the disk for a window nobody is looking at.
    public func refreshing(
        every interval: Duration,
        perform refresh: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(RefreshingModifier(interval: interval, refresh: refresh))
    }
}

private struct RefreshingModifier: ViewModifier {
    let interval: Duration
    let refresh: @MainActor () async -> Void

    @State private var isActive = NSApplication.shared.isActive
    @State private var hasLoaded = false

    func body(content: Content) -> some View {
        content
            .task(id: isActive) {
                // Resigning restarts the task too; what is on screen is already current then.
                if !isActive, hasLoaded { return }
                repeat {
                    await refresh()
                    hasLoaded = true
                    guard isActive else { return }
                    try? await Task.sleep(for: interval)
                } while !Task.isCancelled
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                isActive = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                isActive = false
            }
    }
}
