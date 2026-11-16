import AppKit
import ArchipelCore
import SwiftUI

/// How far the sidebar's content is pulled sideways while a swipe is in progress.
@MainActor @Observable
final class IslandSwipeState {
    var offset = 0.0
    var width = 260.0
    /// Bumped whenever a horizontal gesture starts, so a settle animation that is still finishing
    /// does not switch islands under the fingers.
    fileprivate var generation = 0
    fileprivate var ownsGesture = false
    /// How far the list has come in after a switch made without a swipe, from 0 to 1.
    fileprivate var entrance = 1.0
    /// Which side that list comes in from: 1 from the right, -1 from the left, 0 straight in place.
    fileprivate var entranceSide = 0.0
    /// The swipe settle animates its own way in, so the switch it makes must not add an entrance.
    fileprivate var selectingBySwipe = false
}

extension View {
    /// Slides and fades with the swipe. Applied to the list only, so the header and the island
    /// switcher stay where they are.
    func islandSwipeContent(_ state: IslandSwipeState) -> some View {
        modifier(IslandSwipeContent(state: state))
    }

    /// Listens for two-finger horizontal swipes over this view.
    func islandSwipe(_ state: IslandSwipeState) -> some View {
        modifier(IslandSwipeDriver(state: state))
    }
}

private struct IslandSwipeContent: ViewModifier {
    let state: IslandSwipeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let offset = reduceMotion ? 0 : state.offset
        let entranceOffset = reduceMotion ? 0 : (1 - state.entrance) * state.entranceSide * 14
        content
            .offset(x: offset + entranceOffset)
            .opacity((1 - 0.5 * min(abs(offset) / state.width, 1)) * (0.25 + 0.75 * state.entrance))
            // The offset moves what is drawn, not the layout, so this keeps it inside the sidebar.
            .clipped()
    }
}

private struct IslandSwipeDriver: ViewModifier {
    let state: IslandSwipeState
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            IslandSwipeMonitor(
                begin: { width in
                    state.width = width
                    let islands = model.workspace.islands
                    let selected = islands.firstIndex { $0.id == model.selectedIsland?.id } ?? 0
                    return IslandSwipe(islandCount: islands.count, selectedIndex: selected, width: width)
                },
                changed: {
                    // Vertical scrolls also call begin, so only a gesture that turned out
                    // horizontal may claim the state and cancel a settle in flight.
                    if !state.ownsGesture { state.generation += 1; state.ownsGesture = true }
                    state.offset = $0.offset
                },
                ended: { settle($0) }
            )
        }
        .onChange(of: model.selectedIsland?.id) { old, new in
            enter(from: old, to: new)
        }
    }

    /// Clicks, shortcuts and jumps to a session elsewhere switch islands without a swipe. Without
    /// this the list would swap in a single frame while the switcher below it animates.
    private func enter(from old: Island.ID?, to new: Island.ID?) {
        if state.selectingBySwipe {
            state.selectingBySwipe = false
            return
        }
        let islands = model.workspace.islands
        var side = 0.0
        if let from = islands.firstIndex(where: { $0.id == old }), let to = islands.firstIndex(where: { $0.id == new }) {
            side = to > from ? 1 : -1
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            state.entrance = 0
            state.entranceSide = side
        }
        withAnimation(.smooth(duration: reduceMotion ? 0.2 : 0.32)) { state.entrance = 1 }
    }

    private func settle(_ gesture: IslandSwipe) {
        state.ownsGesture = false
        let target = gesture.settledIndex()
        let generation = state.generation
        let width = state.width
        let start = state.offset
        guard target != gesture.selectedIndex, model.workspace.islands.indices.contains(target) else {
            // Springs back from wherever the fingers let go, at the speed they were moving, so the
            // release does not stop dead before turning around.
            withAnimation(reduceMotion ? nil : Self.settleSpring(velocity: gesture.velocity, distance: -start)) {
                state.offset = 0
            }
            return
        }
        let id = model.workspace.islands[target].id
        if reduceMotion {
            state.offset = 0
            model.select(island: id)
            return
        }
        // Moving right revealed the previous island: the old content leaves to the right and the new
        // one comes in from the left.
        let side: Double = target < gesture.selectedIndex ? 1 : -1
        // Linear and at least as fast as the fingers: any curve that starts from rest makes the list
        // look like it catches on something after a fast flick. It runs all the way out so the
        // island swap below happens while none of the list is on screen.
        let speed = max(side * gesture.velocity, Self.minimumExitSpeed)
        let remaining = max(width - side * start, 0)
        let exit = min(max(remaining / speed, 0.04), 0.16)
        let entry = side * width * Self.entryFraction
        withAnimation(.linear(duration: exit)) {
            state.offset = side * width
        } completion: {
            guard state.generation == generation else {
                // A newer horizontal gesture owns the offset; otherwise nothing else would
                // bring the list back from the slid-out state.
                if !state.ownsGesture {
                    withAnimation(.spring(duration: 0.4, bounce: 0.18)) { state.offset = 0 }
                }
                return
            }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { state.offset = -entry }
            // Only flagged when the selection really changes, or no onChange would clear it.
            if model.selectedIsland?.id != id { state.selectingBySwipe = true }
            model.select(island: id)
            // Picks up the exit's speed, so the new list carries the motion in instead of starting
            // from rest.
            withAnimation(Self.settleSpring(velocity: side * speed, distance: entry)) { state.offset = 0 }
        }
    }

    /// Below this, a slow drag past the commit point would crawl out of the sidebar.
    private static let minimumExitSpeed = 1100.0
    /// How far off-center the new island's list starts, as a share of the width.
    private static let entryFraction = 0.35

    /// A spring toward zero that starts at `velocity` (points per second, positive to the right),
    /// covering `distance` points. SwiftUI wants the start velocity as a share of the distance.
    private static func settleSpring(velocity: Double, distance: Double) -> Animation {
        guard abs(distance) > 1 else { return .spring(duration: 0.35, bounce: 0.12) }
        // Capped because a near-finished distance would turn any speed into a huge share of it,
        // and the spring would overshoot hard.
        let share = min(max(velocity / distance, -8), 18)
        return .interpolatingSpring(duration: 0.38, bounce: 0.12, initialVelocity: share)
    }
}

/// An invisible view that watches scroll-wheel events landing on it. A local monitor is needed
/// because SwiftUI has no hook for the horizontal part of a trackpad scroll, and the sidebar list
/// would swallow it.
private struct IslandSwipeMonitor: NSViewRepresentable {
    let begin: (Double) -> IslandSwipe
    let changed: (IslandSwipe) -> Void
    let ended: (IslandSwipe) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.begin = begin
        context.coordinator.changed = changed
        context.coordinator.ended = ended
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private struct Unchecked: @unchecked Sendable {
        let value: NSEvent?
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var begin: ((Double) -> IslandSwipe)?
        var changed: ((IslandSwipe) -> Void)?
        var ended: ((IslandSwipe) -> Void)?
        private var monitor: Any?
        private var gesture: IslandSwipe?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Local monitors run on the main thread, but the signature does not say so.
                let input = Unchecked(value: event)
                return MainActor.assumeIsolated {
                    guard let self else { return input }
                    return Unchecked(value: self.handle(input.value))
                }.value
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns nil for events that belong to a horizontal swipe, so nothing underneath scrolls.
        private func handle(_ event: NSEvent?) -> NSEvent? {
            guard let event else { return nil }
            // A mouse wheel has no phases and no business switching islands.
            guard event.hasPreciseScrollingDeltas, let view, event.window != nil, event.window === view.window else {
                return event
            }
            if event.phase.contains(.began) {
                gesture = nil
                let point = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(point) { gesture = begin?(view.bounds.width) }
            }
            guard var current = gesture else { return event }

            if event.momentumPhase != [] {
                return current.axis == .horizontal ? nil : event
            }

            // Fingers' direction, whichever way the user set natural scrolling.
            let flip = event.isDirectionInvertedFromDevice ? 1.0 : -1.0
            current.update(dx: event.scrollingDeltaX * flip, dy: event.scrollingDeltaY, time: event.timestamp)
            gesture = current

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                gesture = nil
                if current.axis == .horizontal {
                    ended?(current)
                    return nil
                }
                return event
            }
            if current.axis == .horizontal {
                changed?(current)
                return nil
            }
            return event
        }
    }
}

#if DEBUG
// The gesture itself comes from a scroll wheel monitor and cannot run here; this shows the list at
// rest and partway through a swipe.
private func previewSwipeList(offset: Double) -> some View {
    let state = IslandSwipeState()
    state.offset = offset
    return List {
        ForEach(["main", "feat/offline-mode", "fix/login-crash"], id: \.self) { branch in
            Label(branch, systemImage: "arrow.triangle.branch")
        }
    }
    .islandSwipeContent(state)
    .frame(width: state.width, height: 140)
}

#Preview {
    HStack(spacing: 12) {
        previewSwipeList(offset: 0)
        previewSwipeList(offset: -110)
    }
    .padding()
}
#endif
