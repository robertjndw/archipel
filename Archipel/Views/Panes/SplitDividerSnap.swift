import AppKit
import ArchipelCore
import SwiftUI

extension View {
    /// Makes the divider of the enclosing `HSplitView` catch on the middle while it is dragged, with
    /// a tick from the trackpad. Attach it to one child only, or every child would react.
    func snapsSplitDividerToCenter(enabled: Bool) -> some View {
        background { if enabled { SplitDividerSnapper() } }
    }
}

/// HSplitView hides its NSSplitView, so this finds it from inside and listens for its resizes. Only
/// a plain two-pane split snaps; with more panes there is no single middle.
private struct SplitDividerSnapper: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The view has no superview yet when it is made, so the split view is looked up on updates.
        context.coordinator.attachIfNeeded()
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        private weak var split: NSSplitView?
        private var observer: Any?
        private var isSnapped = false
        private var isAdjusting = false

        func attachIfNeeded() {
            guard split == nil || split?.window == nil, let anchor else { return }
            var candidate = anchor.superview
            while let view = candidate, !(view is NSSplitView) { candidate = view.superview }
            guard let found = candidate as? NSSplitView else { return }
            detach()
            split = found
            observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: found, queue: .main
            ) { [weak self] note in
                // Only a user drag of a divider carries its index; window, sidebar and inspector
                // resizes land here too and must not snap this split.
                let isDividerDrag = note.userInfo?["NSSplitViewDividerIndex"] != nil
                MainActor.assumeIsolated { self?.resized(isDividerDrag: isDividerDrag) }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            split = nil
        }

        private func resized(isDividerDrag: Bool) {
            guard let split, !isAdjusting, split.isVertical, split.arrangedSubviews.count == 2 else { return }
            guard isDividerDrag, NSEvent.pressedMouseButtons & 1 != 0 else {
                isSnapped = false
                return
            }
            let position = split.arrangedSubviews[0].frame.maxX
            let result = SplitSnap.resolve(
                position: position,
                total: split.bounds.width,
                thickness: split.dividerThickness
            )
            if result.snapped {
                if !isSnapped { Haptics.alignment() }
                isSnapped = true
                if abs(result.position - position) >= 0.5 {
                    isAdjusting = true
                    split.setPosition(result.position, ofDividerAt: 0)
                    isAdjusting = false
                }
            } else {
                isSnapped = false
            }
        }
    }
}

extension View {
    /// Turns the hairline of the dividers of the nearest enclosing split view invisible: an
    /// `HSplitView`, or the columns of a `NavigationSplitView` or an inspector when attached to
    /// their content. For views that sit on one surface and need no line between them. The
    /// dividers stay where they are and can still be dragged. In an `HSplitView`, attach it to
    /// every child with the same value, so it holds whichever pane SwiftUI sets up last.
    func hidesSplitDivider(_ isHidden: Bool) -> some View {
        background { SplitDividerHider(isHidden: isHidden) }
    }
}

/// HSplitView has no say over its divider color, and NSSplitView only exposes a getter. The setter
/// exists all the same, and nil hands the color back to AppKit. If a later AppKit drops it, the
/// hairline simply shows in the gap.
private struct SplitDividerHider: NSViewRepresentable {
    let isHidden: Bool

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.hidesDivider = isHidden
    }

    final class Anchor: NSView {
        var hidesDivider = false {
            didSet { if hidesDivider != oldValue { apply() } }
        }

        // It sits behind the pane and must never take a click meant for it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI builds a new split view when the panes change, and this lands in it here.
            if window != nil { apply() }
        }

        private func apply() {
            var candidate = superview
            while let view = candidate, !(view is NSSplitView) { candidate = view.superview }
            guard let split = candidate as? NSSplitView, split.responds(to: Self.setter) else { return }
            split.perform(Self.setter, with: hidesDivider ? NSColor.clear : nil)
            split.needsDisplay = true
            split.subviews.forEach { $0.needsDisplay = true }
        }

        private static let setter = NSSelectorFromString("setDividerColor:")
    }
}
