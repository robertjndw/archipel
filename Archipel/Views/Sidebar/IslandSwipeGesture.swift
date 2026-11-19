import AppKit
import ArchipelCore
import QuartzCore
import SwiftUI

/// Where the islands' lists sit while the sidebar moves between them. At rest the shown island is
/// drawn, plus its neighbours off to the sides while the pointer is over the sidebar, so a swipe
/// never waits for a list to be built. During a swipe or a switch they move as one strip, the way
/// Spaces do.
@MainActor @Observable
final class IslandSwipeState {
    /// How far the strip is moved from `anchor` being centered, positive to the right.
    fileprivate(set) var offset = 0.0
    var width = 260.0
    /// The islands drawn side by side while the strip moves, `anchor` among them. Empty at rest.
    fileprivate var strip: [Island.ID] = []
    /// The island the offset is measured from. It changes only through the swipe and the switch
    /// animation, never by itself, so the list on screen keeps its identity until the strip has
    /// been laid out around it.
    fileprivate var anchor: Island.ID?
    /// Neighbours are drawn at rest while this is set.
    fileprivate var isWarm = false

    /// Settles the strip once a frame. Nil while it is at rest or under the fingers.
    @ObservationIgnored fileprivate var spring: PageSpring?
    @ObservationIgnored private lazy var ticker = FrameTicker { [weak self] in self?.tick($0) }
    @ObservationIgnored fileprivate var ownsGesture = false
    /// Where the strip was when the fingers caught it, less how far they had already moved.
    @ObservationIgnored fileprivate var headStart = 0.0
    /// The strip a swipe would lay out, worked out when it begins, so its indices and the strip
    /// agree even if the swipe takes a few events to turn out horizontal.
    @ObservationIgnored fileprivate var swipeStrip: [Island.ID] = []
    /// Bumped on every switch. A swipe that started before the switch is ignored from then on.
    @ObservationIgnored fileprivate var generation = 0
    @ObservationIgnored fileprivate var swipeGeneration = -1
    /// Set while a swipe makes the switch. The swipe already moves the strip, so `enter` skips it.
    @ObservationIgnored fileprivate var selectingBySwipe = false
    @ObservationIgnored private var cooling: Task<Void, Never>?
    @ObservationIgnored private var scrollPositions: [Island.ID: ScrollPosition] = [:]

    static let response = 0.4

    fileprivate var isMoving: Bool { spring != nil || ownsGesture }

    /// Lets go of the strip where it is and springs it to rest, starting at `velocity`.
    fileprivate func settle(velocity: Double) {
        var spring = PageSpring(position: offset, velocity: velocity, response: Self.response)
        spring.limitOvershoot()
        self.spring = spring
        if !ticker.start() {
            // No display to time frames on, so no animation either. Better a jump than a strip
            // that never comes to rest.
            self.spring = nil
            offset = 0
            fold()
        }
    }

    /// Stops a settle in flight and leaves the strip where it is.
    fileprivate func halt() {
        spring = nil
        ticker.stop()
    }

    /// Moves the strip by `shift` without moving anything on screen: used when the anchor changes,
    /// so a settle in flight keeps going at the same speed toward the new anchor.
    fileprivate func reanchor(to id: Island.ID, shift: Double) {
        anchor = id
        offset += shift
        spring?.position += shift
    }

    private func tick(_ elapsed: Double) {
        guard var spring else { ticker.stop(); return }
        spring.step(elapsed)
        if spring.isSettled {
            self.spring = nil
            ticker.stop()
            offset = 0
            fold()
        } else {
            self.spring = spring
            offset = spring.position
        }
    }

    /// Back to rest on the anchor.
    fileprivate func fold() {
        guard !isMoving else { return }
        strip = []
    }

    fileprivate func hover(_ inside: Bool) {
        cooling?.cancel()
        if inside {
            if !isWarm { isWarm = true }
            return
        }
        // Not right away: the pointer often leaves the sidebar on its way to the switcher and
        // back, and building the lists again each time would cost more than keeping them.
        cooling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, !self.isMoving else { return }
            self.isWarm = false
        }
    }

    /// The pages on screen, in order, `anchor` among them: the moving strip, or at rest the anchor
    /// and, while warm, its neighbours. Shared by the pager and the driver, so a switch or a swipe
    /// starts from exactly the pages that are already drawn and none has to be built mid-motion.
    fileprivate func layout(anchor: Island.ID?, islands: [Island], reduceMotion: Bool) -> [Island.ID] {
        guard let anchor else { return [] }
        // Reduce Motion crossfades in place, one page at a time.
        if reduceMotion { return [anchor] }
        let moving = strip.filter { id in islands.contains { $0.id == id } }
        if moving.contains(anchor) { return moving }
        guard isWarm, let index = islands.firstIndex(where: { $0.id == anchor }) else { return [anchor] }
        return islands[max(index - 1, 0)...min(index + 1, islands.count - 1)].map(\.id)
    }

    /// Each island's list keeps its own scroll position, also across the pages being rebuilt.
    func scrollPosition(of island: Island.ID?) -> Binding<ScrollPosition> {
        Binding(
            get: { [weak self] in island.flatMap { self?.scrollPositions[$0] } ?? ScrollPosition(edge: .top) },
            set: { [weak self] in if let island { self?.scrollPositions[island] = $0 } }
        )
    }
}

/// Calls back once a frame, on the display the app is on, while started.
@MainActor
private final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private let tick: (Double) -> Void

    init(tick: @escaping (Double) -> Void) {
        self.tick = tick
    }

    /// False when there is no display to tick on.
    func start() -> Bool {
        if link != nil { return true }
        guard let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main else { return false }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        last = nil
        return true
    }

    func stop() {
        link?.invalidate()
        link = nil
        last = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = last.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        last = now
        tick(elapsed)
    }
}

extension View {
    /// Listens for two-finger horizontal swipes over this view and moves the strip for every
    /// island switch, however it was made.
    func islandSwipe(_ state: IslandSwipeState, isEnabled: Bool = true) -> some View {
        modifier(IslandSwipeDriver(state: state, isEnabled: isEnabled))
    }
}

/// Draws `page` for the shown island, and for the others in the strip. Only the selected island's
/// page takes clicks and is seen by accessibility.
struct IslandPager<Page: View>: View {
    let state: IslandSwipeState
    @ViewBuilder let page: (Island?) -> Page
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let islands = model.workspace.islands
        let selected = model.selectedIsland?.id
        let anchor = state.anchor.flatMap { model.workspace.island(id: $0) }?.id ?? selected
        let strip = state.layout(anchor: anchor, islands: islands, reduceMotion: reduceMotion)
        let anchorPosition = strip.firstIndex { $0 == anchor } ?? 0
        ZStack {
            if strip.isEmpty {
                page(nil)
            }
            ForEach(Array(strip.enumerated()), id: \.element) { position, id in
                let isCurrent = id == selected
                PageSlot(state: state, position: reduceMotion ? 0 : position - anchorPosition) {
                    page(model.workspace.island(id: id))
                }
                .allowsHitTesting(isCurrent)
                .accessibilityHidden(!isCurrent)
            }
        }
        // The offset moves what is drawn, not the layout, so this keeps the strip inside the sidebar.
        .clipped()
        .onGeometryChange(for: Double.self) { $0.size.width } action: { state.width = $0 }
        .onHover { state.hover($0) }
    }
}

/// Reads the offset on its own, so moving the strip once a frame redraws this and not the lists.
private struct PageSlot<Content: View>: View {
    let state: IslandSwipeState
    let position: Int
    @ViewBuilder let content: Content

    var body: some View {
        content.offset(x: Double(position) * state.width + state.offset)
    }
}

private struct IslandSwipeDriver: ViewModifier {
    let state: IslandSwipeState
    let isEnabled: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            // Dropping the monitor stops it from claiming scroll events, which a list that spans every
            // island has no use for.
            if isEnabled {
                IslandSwipeMonitor(
                    begin: { begin(width: $0) },
                    changed: { follow($0) },
                    ended: { release($0) }
                )
            }
        }
        .onAppear { if state.anchor == nil { state.anchor = model.selectedIsland?.id } }
        .onChange(of: model.selectedIsland?.id) { old, new in enter(from: old, to: new) }
        .onChange(of: isEnabled) { if !isEnabled { rest(at: model.selectedIsland?.id) } }
    }

    // MARK: Swipe

    /// Runs for every two-finger scroll, vertical ones too, so it only works out what a horizontal
    /// swipe would do and leaves the strip alone.
    private func begin(width: Double) -> IslandSwipe {
        state.width = width
        state.swipeGeneration = state.generation
        let strip = grabbableStrip()
        state.swipeStrip = strip
        let index = strip.firstIndex { $0 == currentAnchor } ?? 0
        return IslandSwipe(islandCount: strip.count, selectedIndex: index, width: width)
    }

    private func follow(_ gesture: IslandSwipe) {
        guard state.swipeGeneration == state.generation else { return }
        if !state.ownsGesture {
            // The fingers caught the strip. Stop it where it is and follow them from here.
            state.halt()
            state.ownsGesture = true
            state.headStart = reduceMotion ? 0 : state.offset - gesture.translation
            withTransaction(Self.instant) {
                state.strip = state.swipeStrip
                state.anchor = currentAnchor
            }
        }
        guard !reduceMotion else { return }
        var gesture = gesture
        gesture.headStart = state.headStart
        withTransaction(Self.instant) { state.offset = gesture.offset }
    }

    private func release(_ gesture: IslandSwipe) {
        guard state.ownsGesture, state.swipeGeneration == state.generation else { return }
        state.ownsGesture = false
        var gesture = gesture
        gesture.headStart = state.headStart
        let strip = state.swipeStrip
        let target = gesture.settledIndex()
        guard target != gesture.selectedIndex, strip.indices.contains(target) else {
            reduceMotion ? rest(at: currentAnchor) : state.settle(velocity: gesture.velocity)
            return
        }
        let id = strip[target]
        if model.selectedIsland?.id != id { state.selectingBySwipe = true }
        if reduceMotion {
            crossfade(to: id)
            model.select(island: id)
            return
        }
        // Re-anchor on the target. Nothing moves on screen, but selecting now lets the switcher
        // and the window update while the strip is still settling.
        withTransaction(Self.instant) {
            state.reanchor(to: id, shift: Double(target - gesture.selectedIndex) * state.width)
        }
        model.select(island: id)
        state.settle(velocity: gesture.velocity)
    }

    // MARK: Switches

    /// Shortcuts, menu items, clicks and session jumps change the island without a swipe. The old
    /// list is still on screen when this runs, so both slide together: the old one out, the new one
    /// in. A switch that comes while the strip is still moving takes it over at the same speed.
    private func enter(from old: Island.ID?, to new: Island.ID?) {
        if state.selectingBySwipe {
            state.selectingBySwipe = false
            return
        }
        // A swipe in progress loses the strip to the switch; its remaining events are dropped.
        state.generation += 1
        state.ownsGesture = false
        let islands = model.workspace.islands
        guard isEnabled, let new, islands.contains(where: { $0.id == new }) else {
            rest(at: new)
            return
        }
        if reduceMotion {
            crossfade(to: new)
            return
        }
        let anchor = currentAnchor
        guard let anchor, anchor != new,
              let from = islands.firstIndex(where: { $0.id == old ?? anchor }),
              let to = islands.firstIndex(where: { $0.id == new })
        else {
            rest(at: new)
            return
        }
        var strip = state.layout(anchor: anchor, islands: islands, reduceMotion: false)
        let anchorPosition = strip.firstIndex(of: anchor) ?? 0
        if strip.isEmpty { strip = [anchor] }
        if !strip.contains(new) {
            // Put it next to the centered page, on the side where the new island is. It replaces
            // whatever was in that slot; only the anchor and its direct neighbours can be on screen.
            if to > from {
                if anchorPosition + 1 < strip.count { strip[anchorPosition + 1] = new } else { strip.append(new) }
            } else {
                if anchorPosition > 0 { strip[anchorPosition - 1] = new } else { strip.insert(new, at: 0) }
            }
        }
        let shift = Double(strip.firstIndex(of: new)! - strip.firstIndex(of: anchor)!) * state.width
        let wasMoving = state.spring != nil
        withTransaction(Self.instant) {
            state.strip = strip
            state.reanchor(to: new, shift: shift)
        }
        if !wasMoving { state.settle(velocity: 0) }
    }

    /// Reduce Motion: no sliding, the lists fade into each other in place.
    private func crossfade(to id: Island.ID) {
        state.halt()
        withTransaction(Self.instant) {
            state.strip = []
            state.offset = 0
        }
        withAnimation(.easeInOut(duration: 0.2)) { state.anchor = id }
    }

    private func rest(at id: Island.ID?) {
        state.halt()
        state.ownsGesture = false
        withTransaction(Self.instant) {
            state.strip = []
            state.anchor = id
            state.offset = 0
        }
    }

    // MARK: Layout

    private var currentAnchor: Island.ID? {
        state.anchor.flatMap { model.workspace.island(id: $0) }?.id ?? model.selectedIsland?.id
    }

    /// The strip a swipe starting now would move: what is on screen around the anchor, and the
    /// anchor's own neighbours on any side where nothing is.
    private func grabbableStrip() -> [Island.ID] {
        let islands = model.workspace.islands
        guard let anchor = currentAnchor, let index = islands.firstIndex(where: { $0.id == anchor }) else { return [] }
        var strip = state.layout(anchor: anchor, islands: islands, reduceMotion: false)
        guard let position = strip.firstIndex(of: anchor) else { return [anchor] }
        strip = Array(strip[max(position - 1, 0)...min(position + 1, strip.count - 1)])
        if strip.first == anchor, index > 0 { strip.insert(islands[index - 1].id, at: 0) }
        if strip.last == anchor, index < islands.count - 1 { strip.append(islands[index + 1].id) }
        return strip
    }

    private static var instant: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
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
