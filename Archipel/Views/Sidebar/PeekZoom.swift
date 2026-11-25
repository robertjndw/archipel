import AppKit
import ArchipelCore
import SwiftUI

/// A picture of the peek's content and where it sat on screen, taken as Return is pressed.
struct PeekSnapshot {
    let image: NSImage
    let screenFrame: CGRect
}

/// Sits behind the popover's content, so its bounds are the content's and it can photograph it.
struct PeekSnapshotSource: NSViewRepresentable {
    let peek: SidebarPeekModel
    let worktree: Worktree.ID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        peek.setSnapshotSource(view, for: worktree)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        peek.setSnapshotSource(view, for: worktree)
    }
}

extension NSView {
    /// Draws whatever shares this view's frame in its window, the SwiftUI content in front of it
    /// included. The popover's own glass is drawn by the window server and does not come along,
    /// which is fine: the peek paints its own opaque surface.
    func peekSnapshot() -> PeekSnapshot? {
        guard let window, let content = window.contentView else { return nil }
        let rect = convert(bounds, to: content)
        guard rect.width > 1, rect.height > 1, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return PeekSnapshot(image: image, screenFrame: window.convertToScreen(convert(bounds, to: nil)))
    }
}

/// Where the zoom lands: a pane's frame in SwiftUI's global space of the main window, and its corner radius.
struct PeekZoomDestination: Equatable {
    var frame: CGRect
    var radius: CGFloat
}

/// Makes opening a peek look like the peek growing into the pane that now shows the session.
///
/// The popover is a window of its own and the terminal is a Metal surface, so neither can be
/// animated in place. Instead a picture of the peek goes into a borderless child window over the
/// main window, the selection changes under it, and the picture grows into the pane's frame and
/// fades once it is there. A child window rather than a subview of the content: SwiftUI inserts the
/// new terminal's view into its own hierarchy while this runs, and could put it above an overlay
/// that lived there.
///
/// Anything that would make the picture lie (a resize, a key, a click, a selection that never
/// lands) drops it at once; the real content is already underneath.
@MainActor
final class PeekZoom {
    private var overlay: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var poll: Task<Void, Never>?

    /// Corner radius of the system popover's content on macOS 27, where the zoom starts.
    static let popoverRadius: CGFloat = 16

    /// - Parameters:
    ///   - destination: Asked about every frame for a short while after `select` until it returns the
    ///     pane. It returns nil while the pane is still being laid out, or if the selection did not
    ///     land where the peek pointed.
    func run(
        from snapshot: PeekSnapshot,
        over window: NSWindow,
        background: Color,
        select: () -> Void,
        destination: @escaping () -> PeekZoomDestination?
    ) {
        cancel()
        guard let content = window.contentView else {
            select()
            return
        }
        // The popover can stick out past the window's top or side, so the overlay covers both.
        let bounds = window.frame.union(snapshot.screenFrame)
        let overlay = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.transient, .ignoresCycle]
        overlay.animationBehavior = .none

        let state = PeekZoomState(
            image: snapshot.image,
            frame: Self.local(snapshot.screenFrame, in: bounds),
            radius: Self.popoverRadius,
            background: background
        )
        overlay.contentView = NSHostingView(rootView: PeekZoomCard(state: state) { [weak self, weak overlay] in
            // A newer zoom may have replaced this one by the time its fade ends.
            if let self, self.overlay === overlay { self.cancel() }
        })
        window.addChildWindow(overlay, ordered: .above)
        self.overlay = overlay

        // Typing or clicking means the user is already working in what is underneath.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.cancel()
            return event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }

        select()

        // The pane frames come from SwiftUI's layout, which runs after the selection has changed,
        // so the destination may take a frame or two to exist.
        poll = Task { [weak self, weak window] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let window else { return }
                if let target = destination() {
                    state.land(on: PeekZoomDestination(
                        frame: Self.local(Self.screenRect(ofGlobal: target.frame, in: content, of: window), in: bounds),
                        radius: target.radius
                    ))
                    break
                }
            }
            if state.destination == nil { state.abandon() }
            // However the animation goes, the overlay must not outlive it by much.
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func cancel() {
        poll?.cancel()
        poll = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let overlay {
            overlay.parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
            overlay.contentView = nil
        }
        overlay = nil
    }

    /// A screen rect in the overlay's own top-left-origin space.
    private static func local(_ rect: CGRect, in overlay: CGRect) -> CGRect {
        CGRect(x: rect.minX - overlay.minX, y: overlay.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// SwiftUI's global space on macOS is the hosting view's, with a top-left origin.
    private static func screenRect(ofGlobal rect: CGRect, in content: NSView, of window: NSWindow) -> CGRect {
        let local = content.isFlipped ? rect : CGRect(
            x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return window.convertToScreen(content.convert(local, to: nil))
    }
}

@Observable
@MainActor
final class PeekZoomState {
    let image: NSImage
    let start: CGRect
    let startRadius: CGFloat
    let background: Color
    private(set) var destination: PeekZoomDestination?
    private(set) var isAbandoned = false

    init(image: NSImage, frame: CGRect, radius: CGFloat, background: Color) {
        self.image = image
        start = frame
        startRadius = radius
        self.background = background
    }

    func land(on destination: PeekZoomDestination) {
        self.destination = destination
    }

    func abandon() {
        isAbandoned = true
    }
}

/// The moving card. It owns the animation so it can follow Reduce Motion the way the rest of the
/// views do.
private struct PeekZoomCard: View {
    let state: PeekZoomState
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: CGRect?
    @State private var radius: CGFloat?
    @State private var pictureOpacity = 1.0
    @State private var opacity = 1.0

    /// Close to the system's window and sheet springs. No bounce, or the card would overshoot the
    /// pane and its corners would show past the edges.
    private static let zoom = Animation.spring(duration: 0.32, bounce: 0)

    var body: some View {
        let frame = frame ?? state.start
        let shape = RoundedRectangle(cornerRadius: radius ?? state.startRadius, style: Chrome.paneCornerStyle)
        // The picture keeps its aspect ratio and scales with the card's width. It fades out before it
        // gets blurry, and by then the card already has the pane's color and shape.
        Image(nsImage: state.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .opacity(pictureOpacity)
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .background(state.background)
            .clipShape(shape)
            .opacity(opacity)
            .position(x: frame.midX, y: frame.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: state.destination) { _, destination in
                guard let destination else { return }
                if reduceMotion {
                    // No travel: the peek just gives way to the pane behind it.
                    fadeOut(duration: 0.2)
                    return
                }
                withAnimation(.easeIn(duration: 0.24)) { pictureOpacity = 0 }
                withAnimation(Self.zoom) {
                    self.frame = destination.frame
                    radius = destination.radius
                } completion: {
                    // The terminal is under the card by now, so fading the card out is the cross-fade.
                    fadeOut(duration: 0.15)
                }
            }
            .onChange(of: state.isAbandoned) { _, abandoned in
                if abandoned { fadeOut(duration: 0.15) }
            }
    }

    private func fadeOut(duration: Double) {
        withAnimation(.easeOut(duration: duration)) { opacity = 0 } completion: { finished() }
    }
}
