import AppKit
import ArchipelCore
import SwiftUI

extension View {
    /// Gives the panes of the enclosing `HSplitView` equal widths whenever one is added or closed,
    /// and makes a single divider catch on the middle while it is dragged, with a tick from the
    /// trackpad. Attach it to one child only, or every child would react.
    func centersSplitDivider(enabled: Bool) -> some View {
        background { if enabled { SplitDividerSnapper() } }
    }
}

/// HSplitView hides its NSSplitView, so this finds it from inside and listens for its resizes. Only
/// a plain two-pane split snaps; with more panes there is no single middle.
///
/// HSplitView only lays out the panes it starts with evenly. A pane added later ends up wherever
/// AppKit puts it, which was about 40/60 for a fresh split.
private struct SplitDividerSnapper: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.coordinator = context.coordinator
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        // The view has no superview yet when it is made, so the split view is looked up on updates.
        context.coordinator.attachIfNeeded()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Anchor: NSView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Adding a pane moves the existing ones into a new split view, and SwiftUI doesn't call
            // updateNSView for that, so this is the only place to notice.
            if window != nil { coordinator?.attachIfNeeded() }
        }
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        private weak var split: NSSplitView?
        private var observer: Any?
        private var isSnapped = false
        private var isAdjusting = false
        /// The pane count the widths were last evened out for, so it happens once per change.
        private var balancedCount = 0

        func attachIfNeeded() {
            guard let anchor else { return }
            var candidate = anchor.superview
            while let view = candidate, !(view is NSSplitView) { candidate = view.superview }
            guard let found = candidate as? NSSplitView, found !== split else { return }
            detach()
            split = found
            balancedCount = 0
            observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: found, queue: .main
            ) { [weak self] note in
                // Only a user drag of a divider carries its index; window, sidebar and inspector
                // resizes land here too and must not snap this split.
                let isDividerDrag = note.userInfo?["NSSplitViewDividerIndex"] != nil
                MainActor.assumeIsolated { self?.resized(isDividerDrag: isDividerDrag) }
            }
            balanceIfPanesChanged()
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            split = nil
        }

        private func resized(isDividerDrag: Bool) {
            guard let split, !isAdjusting, split.isVertical else { return }
            // Adding a pane also reports a divider index, so it looks like a drag here. Only the
            // pane count tells them apart.
            balanceIfPanesChanged()
            guard split.arrangedSubviews.count == 2 else { return }
            guard isDividerDrag, NSEvent.pressedMouseButtons & 1 != 0 else {
                isSnapped = false
                return
            }
            let visible = Self.visibleRange(of: split)
            let position = split.arrangedSubviews[0].frame.maxX
            let result = SplitSnap.resolve(
                position: position - visible.lowerBound,
                total: visible.upperBound - visible.lowerBound,
                thickness: split.dividerThickness
            )
            if result.snapped {
                if !isSnapped { Haptics.alignment() }
                isSnapped = true
                let snapped = result.position + visible.lowerBound
                if abs(snapped - position) >= 0.5 {
                    isAdjusting = true
                    split.setPosition(snapped, ofDividerAt: 0)
                    isAdjusting = false
                }
            } else {
                isSnapped = false
            }
        }

        /// Runs on the next pass of the main queue. Right after a pane is added SwiftUI is still
        /// laying out the split and would undo dividers moved any earlier.
        private func balanceIfPanesChanged() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let split = self.split, split.isVertical, split.bounds.width > 0 else { return }
                let count = split.arrangedSubviews.count
                guard count != self.balancedCount else { return }
                self.balancedCount = count
                self.balance(split, count: count)
            }
        }

        private func balance(_ split: NSSplitView, count: Int) {
            guard count > 1 else { return }
            let visible = Self.visibleRange(of: split)
            let thickness = split.dividerThickness
            let available = visible.upperBound - visible.lowerBound - thickness * CGFloat(count - 1)
            guard available > 0 else { return }
            let width = available / CGFloat(count)
            isAdjusting = true
            // Left to right, so each divider is placed next to a pane that already has its width.
            for index in 0..<(count - 1) {
                let position = visible.lowerBound + width * CGFloat(index + 1) + thickness * CGFloat(index)
                split.setPosition(position, ofDividerAt: index)
            }
            isAdjusting = false
        }

        /// The part of the split that isn't covered by the sidebar or the inspector. The split runs
        /// underneath both and reports them as its safe area. Splitting the full width in half would
        /// make the pane next to the narrower column visibly wider.
        private static func visibleRange(of split: NSSplitView) -> ClosedRange<CGFloat> {
            let insets = split.safeAreaInsets
            let lower = insets.left
            return lower...max(lower, split.bounds.width - insets.right)
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
