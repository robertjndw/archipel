import AppKit
import ArchipelCore
import SwiftUI

extension View {
    /// Gives the panes of the enclosing `HSplitView` the widths the workspace remembers for them,
    /// which are equal ones after a pane was added or closed, and makes a single divider catch on
    /// the middle while it is dragged, with a tick from the trackpad. Attach it to one child only,
    /// or every child would react.
    ///
    /// `panes` and `shares` are the panes in order and each one's share of the width. `onResize`
    /// gets the new shares once the user has let go of a divider.
    func centersSplitDivider(
        enabled: Bool,
        panes: [Pane.ID],
        shares: [Double],
        onResize: @escaping ([Double]) -> Void
    ) -> some View {
        background { if enabled { SplitDividerSnapper(panes: panes, shares: shares, onResize: onResize) } }
    }
}

/// HSplitView hides its NSSplitView, so this finds it from inside and listens for its resizes. Only
/// a plain two-pane split snaps; with more panes there is no single middle.
///
/// HSplitView only lays out the panes it starts with evenly. A pane added later ends up wherever
/// AppKit puts it, which was about 40/60 for a fresh split. It also keeps no widths of its own:
/// every worktree switch and every launch builds the split anew, so the widths are put back from
/// the workspace each time.
private struct SplitDividerSnapper: NSViewRepresentable {
    let panes: [Pane.ID]
    let shares: [Double]
    let onResize: ([Double]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.coordinator = context.coordinator
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.panes = panes
        context.coordinator.shares = shares
        context.coordinator.onResize = onResize
        // The view has no superview yet when it is made, so the split view is looked up on updates.
        context.coordinator.attachIfNeeded()
        context.coordinator.layOutIfPanesChanged()
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
        var panes: [Pane.ID] = []
        var shares: [Double] = []
        var onResize: ([Double]) -> Void = { _ in }
        /// The panes the dividers were last placed for, so it happens once per change and a width
        /// the user dragged is not put back on the next update.
        private var laidOutPanes: [Pane.ID]?
        private var isAwaitingDragEnd = false

        func attachIfNeeded() {
            guard let anchor else { return }
            guard let found = anchor.enclosingSplitView, found !== split else { return }
            detach()
            split = found
            laidOutPanes = nil
            observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: found, queue: .main
            ) { [weak self] note in
                // Only a user drag of a divider carries its index; window, sidebar and inspector
                // resizes land here too and must not snap this split.
                let isDividerDrag = note.userInfo?["NSSplitViewDividerIndex"] != nil
                MainActor.assumeIsolated { self?.resized(isDividerDrag: isDividerDrag) }
            }
            layOutIfPanesChanged()
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            split = nil
        }

        private func resized(isDividerDrag: Bool) {
            guard let split, !isAdjusting, split.isVertical else { return }
            // Adding a pane also reports a divider index, so it looks like a drag here. Only the
            // panes themselves tell them apart.
            layOutIfPanesChanged()
            if isDividerDrag, NSEvent.pressedMouseButtons & 1 != 0 { reportWhenDragEnds() }
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
        func layOutIfPanesChanged() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let split = self.split, split.isVertical, split.bounds.width > 0 else { return }
                // While SwiftUI has not caught up with the workspace the two disagree about the
                // panes. The resize that follows once it has comes back here.
                guard split.arrangedSubviews.count == self.panes.count, self.panes != self.laidOutPanes else { return }
                self.laidOutPanes = self.panes
                self.layOut(split)
            }
        }

        private func layOut(_ split: NSSplitView) {
            let visible = Self.visibleRange(of: split)
            let count = split.arrangedSubviews.count
            let positions = SplitShares.dividerPositions(
                shares: shares.count == count ? shares : Array(repeating: 1, count: count),
                total: visible.upperBound - visible.lowerBound,
                thickness: split.dividerThickness
            )
            isAdjusting = true
            // Left to right, so each divider is placed next to a pane that already has its width.
            for (index, position) in positions.enumerated() {
                split.setPosition(visible.lowerBound + position, ofDividerAt: index)
            }
            isAdjusting = false
        }

        /// The split reports every step of a drag. Writing the workspace on each would save and
        /// redraw all the way through it, so the widths are read once the button is up. AppKit
        /// tracks the drag in a loop of its own and sends no event for its end, hence the polling.
        private func reportWhenDragEnds() {
            guard !isAwaitingDragEnd else { return }
            isAwaitingDragEnd = true
            pollDragEnd()
        }

        private func pollDragEnd() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                guard let self else { return }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return self.pollDragEnd() }
                self.isAwaitingDragEnd = false
                self.reportShares()
            }
        }

        private func reportShares() {
            // Only for the panes the dividers were placed for: in the middle of a split or a
            // worktree switch the widths belong to nothing the workspace could file them under.
            guard let split, split.isVertical, split.arrangedSubviews.count == panes.count, panes == laidOutPanes else { return }
            let visible = Self.visibleRange(of: split)
            // The outer panes run on underneath the sidebar and the inspector; only what shows counts.
            let widths = split.arrangedSubviews.map { view in
                Double(min(view.frame.maxX, visible.upperBound) - max(view.frame.minX, visible.lowerBound))
            }
            if let shares = SplitShares.shares(widths: widths) { onResize(shares) }
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
            guard let split = enclosingSplitView, split.responds(to: Self.setter) else { return }
            split.perform(Self.setter, with: hidesDivider ? NSColor.clear : nil)
            split.needsDisplay = true
            split.subviews.forEach { $0.needsDisplay = true }
        }

        private static let setter = NSSelectorFromString("setDividerColor:")
    }
}

private extension NSView {
    /// The NSSplitView SwiftUI created for the `HSplitView` or `NavigationSplitView` this view is in.
    var enclosingSplitView: NSSplitView? {
        var candidate = superview
        while let view = candidate, !(view is NSSplitView) { candidate = view.superview }
        return candidate as? NSSplitView
    }
}
