import AppKit
import ArchipelCore
import QuartzCore
import SwiftUI

/// Where the islands' lists sit while the sidebar moves between them. At rest the shown island is
/// drawn, plus its neighbours off to the sides while the pointer is over the sidebar, so a swipe
/// never waits for a list to be built. During a swipe or a switch they move as one strip, the way
/// Spaces do.
///
/// The strip is moved by Core Animation, which keeps the display's frame rate while the app is
/// busy putting the new island's content on screen. Every motion is a spring that is added on top
/// of the ones still running. A switch that comes while the strip is moving therefore leaves the
/// motion on screen alone and only adds the way to the new island, so it joins in without a jump
/// whenever it gets to the screen, even if the main thread took several frames to send it there.
@MainActor @Observable
final class IslandSwipeState {
    /// The islands drawn side by side while the strip moves, `anchor` among them. Empty at rest.
    fileprivate var strip: [Island.ID] = []
    /// The island the offset is measured from. It changes only through the swipe and the switch
    /// animation, never by itself, so the list on screen keeps its identity until the strip has
    /// been laid out around it.
    fileprivate var anchor: Island.ID?
    /// Neighbours are drawn at rest while this is set.
    fileprivate var isWarm = false

    @ObservationIgnored fileprivate var width = 260.0
    @ObservationIgnored fileprivate weak var surface: IslandStripView?

    /// How far the strip is moved from `anchor` being centered, positive to the right, not
    /// counting the springs. Zero unless the fingers hold it.
    @ObservationIgnored fileprivate private(set) var held = 0.0
    /// Springs the view has yet to put on screen.
    @ObservationIgnored fileprivate private(set) var launching: [PageSpring] = []
    /// Springs under way, the ones in `launching` included.
    @ObservationIgnored private var springCount = 0
    /// Bumped when the springs are dropped. One that ends after that is not counted.
    @ObservationIgnored fileprivate private(set) var flight = 0

    @ObservationIgnored fileprivate var ownsGesture = false
    /// Where the strip was when the fingers caught it, less how far they had already moved.
    @ObservationIgnored fileprivate var headStart = 0.0
    /// Whether the swipe was past the halfway point at its last event.
    @ObservationIgnored fileprivate var isPastCommitPoint = false
    /// The strip a swipe would lay out, worked out when it begins, so its indices and the strip
    /// agree even if the swipe takes a few events to turn out horizontal.
    @ObservationIgnored fileprivate var swipeStrip: [Island.ID] = []
    /// Bumped on every switch. A swipe that started before the switch is ignored from then on.
    @ObservationIgnored fileprivate var generation = 0
    @ObservationIgnored fileprivate var swipeGeneration = -1
    @ObservationIgnored private var cooling: Task<Void, Never>?
    @ObservationIgnored private var isHovered = false
    /// Where each island's list was scrolled to when its page was last taken down.
    @ObservationIgnored fileprivate var scrollAnchors: [Island.ID: ListScrollAnchor] = [:]

    /// The spring's response when a swipe is let go short of halfway and the strip goes back.
    static let swipeResponse = 0.3
    /// The response for a switch by a shortcut or a click.
    static let switchResponse = 0.25
    /// The response when a swipe is let go and the next island drops into place. The shortest:
    /// the fingers have already brought it part of the way, and at their speed.
    static let dropResponse = 0.2
    /// Just under critical: the strip reaches the island sooner than it would at 1 and lands
    /// crisply, passing it by no more than a point before it rests.
    static let damping = 0.9

    fileprivate var isMoving: Bool { springCount > 0 || ownsGesture }

    /// The island the sidebar shows or is on its way to. It changes the moment a switch starts,
    /// ahead of the model's selection, which is what lets the switcher's highlight leave together
    /// with the lists.
    var heading: Island.ID? { anchor }

    /// Where the strip is right now, as it is on screen.
    fileprivate var offset: Double {
        held + (surface?.springOffset ?? 0) + launching.reduce(0) { $0 + $1.position }
    }

    /// Puts the strip where the fingers are.
    fileprivate func follow(_ offset: Double) {
        dropSprings()
        held = offset
        surface?.render()
    }

    /// Lets go of the strip where it is held and springs it to rest, starting at `velocity`.
    fileprivate func settle(velocity: Double, response: Double) {
        var spring = PageSpring(position: held, velocity: velocity, response: response, damping: Self.damping)
        spring.limitOvershoot()
        held = 0
        // Off screen there is nothing to animate and nothing that would report the end of it.
        if surface?.window != nil, !spring.isSettled {
            launching.append(spring)
            springCount += 1
        }
        surface?.render()
        fold()
    }

    /// Stops the strip where it is on screen and holds it there.
    fileprivate func halt() {
        guard springCount > 0 else { return }
        let offset = offset
        dropSprings()
        held = offset
        surface?.render()
    }

    /// Changes the anchor without moving anything on screen: the strip is held as far from the
    /// new anchor as that is from the old one. Springs under way keep going as they are.
    fileprivate func reanchor(to id: Island.ID, shift: Double) {
        anchor = id
        held += shift
    }

    /// At rest on the anchor, without animation.
    fileprivate func reset() {
        dropSprings()
        held = 0
        surface?.render()
    }

    private func dropSprings() {
        launching = []
        springCount = 0
        flight += 1
    }

    fileprivate func didLaunch() {
        launching = []
    }

    /// A spring of `flight` ran to its end.
    fileprivate func landed(flight: Int) {
        guard flight == self.flight, springCount > 0 else { return }
        springCount -= 1
        fold()
    }

    /// Back to rest on the anchor.
    fileprivate func fold() {
        guard !isMoving, !strip.isEmpty else { return }
        strip = []
    }

    fileprivate func hover(_ inside: Bool) {
        isHovered = inside
        // Not right away: the pointer often leaves the sidebar on its way to the switcher and
        // back, and building the lists again each time would cost more than keeping them.
        keepWarm(for: .seconds(3))
    }

    /// One switch is often followed by another, by shortcut with the pointer nowhere near the
    /// sidebar. With the neighbours already built, the next one starts without building a list.
    fileprivate func switched() {
        keepWarm(for: .seconds(20))
    }

    private func keepWarm(for duration: Duration) {
        cooling?.cancel()
        if !isWarm { isWarm = true }
        guard !isHovered else { return }
        cooling = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled, !self.isMoving, !self.isHovered else { return }
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

}

extension View {
    /// Listens for two-finger horizontal swipes over this view and moves the strip for every
    /// island switch, however it was made.
    func islandSwipe(_ state: IslandSwipeState, isEnabled: Bool = true) -> some View {
        modifier(IslandSwipeDriver(state: state, isEnabled: isEnabled))
    }
}

/// A place in a list that a new list with the same rows can be scrolled back to. Not a distance
/// from the top: a new list works with estimated row heights until it has drawn its rows, so the
/// same distance is a different place in it, or past its end.
fileprivate struct ListScrollAnchor {
    /// The row at the top edge.
    let row: Int
    /// How far that row is scrolled past the top edge.
    let offset: CGFloat
}

/// Draws `page` for the shown island, and for the others in the strip. Only the selected island's
/// page takes clicks and is seen by accessibility.
struct IslandPager<Page: View>: View {
    let state: IslandSwipeState
    @ViewBuilder let page: (Island?) -> Page
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selected = model.selectedIsland?.id
        let anchor = state.anchor.flatMap { model.workspace.island(id: $0) }?.id ?? selected
        let strip = state.layout(anchor: anchor, islands: model.workspace.islands, reduceMotion: reduceMotion)
        // Without an island there is still one page, the empty list.
        IslandStrip(
            state: state, order: strip.isEmpty ? [nil] : strip, anchor: anchor,
            islands: model.workspace.islands.map(\.id), crossfades: reduceMotion, page: page
        )
        .onHover { state.hover($0) }
    }
}

/// One page of the strip. A view of its own so that what the page reads from the model is
/// observed inside the page's own hosting view.
private struct IslandPage<Page: View>: View {
    let id: Island.ID?
    let page: (Island?) -> Page
    @Environment(AppModel.self) private var model

    var body: some View {
        let isCurrent = id == model.selectedIsland?.id
        page(id.flatMap { model.workspace.island(id: $0) })
            .allowsHitTesting(isCurrent)
            .accessibilityHidden(!isCurrent)
            // A list kept next to the shown one would otherwise animate every change to its rows
            // off screen, which costs the main thread as much as if it were seen.
            .transaction { transaction in
                guard !isCurrent else { return }
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

/// The strip is an AppKit view with a hosting view per page, because only a layer can be moved
/// by Core Animation, and SwiftUI does not give its views one to animate.
private struct IslandStrip<Page: View>: NSViewRepresentable {
    let state: IslandSwipeState
    let order: [Island.ID?]
    let anchor: Island.ID?
    let islands: [Island.ID]
    let crossfades: Bool
    let page: (Island?) -> Page

    func makeNSView(context: Context) -> IslandStripView {
        IslandStripView(state: state)
    }

    func updateNSView(_ view: IslandStripView, context: Context) {
        // A hosting view starts with an empty environment. The pages get the sidebar's, with the
        // model, the list style and the tint in it.
        let environment = context.environment
        view.update(order: order, anchor: anchor, islands: islands, crossfades: crossfades) { id in
            AnyView(IslandPage(id: id, page: page).environment(\.self, environment))
        }
    }
}

/// Lays the pages out side by side around the anchor. Under the fingers the pages are moved by
/// their frames: AppKit only draws what it takes to be on screen, so it has to know where they
/// are, or the list coming in stays empty. The springs move them all through the layer's sublayer
/// transform, which AppKit leaves alone, unlike the frames and transforms of the views. That is
/// fine for a spring: it always ends on the page that AppKit already has in view.
@MainActor
private final class IslandStripView: NSView {
    private let state: IslandSwipeState
    private var pages: [Island.ID?: NSHostingView<AnyView>] = [:]
    private var order: [Island.ID?] = []
    /// Builds a page's content, kept from the last update for pages made before the next one.
    private var content: ((Island.ID?) -> AnyView)?
    /// The anchor the pager asked for, for when the state has none of its own or a stale one.
    private var fallbackAnchor: Island.ID?
    private var hasLaidOut = false
    /// What the pager last asked for.
    private var wanted: (order: [Island.ID?], anchor: Island.ID?, crossfades: Bool)?
    private var hasBeenAskedForAccessibility = false
    /// Islands whose new list has yet to be scrolled back to where the last one was.
    private var awaitingScroll: [Island.ID: ListScrollAnchor] = [:]
    /// The island on screen and the one that was there before it.
    private var shown: Island.ID?
    private var lastVisited: Island.ID?
    /// The last visited island's page once the strip has no more use for it, kept out of sight.
    /// Going back to the island you just left is the most common switch, and this way it does not
    /// have to build the list again. Only one page, so the lists that are kept do not add up.
    private var parked: (id: Island.ID, page: NSHostingView<AnyView>)?
    private var springKeys: [String] = []
    private var nextSpringKey = 0
    private var shownFlight = 0

    private static let fadeDuration = 0.2

    init(state: IslandSwipeState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        // The pages next to the shown one are laid out beyond the bounds.
        clipsToBounds = true
        state.surface = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A hosting view builds accessibility elements only if a client was already asking for them
    /// when it was made. The first page is made at launch, before any client, and would stay
    /// empty for VoiceOver and for UI tests until a switch replaced it. So the first time
    /// someone asks, the pages made until then are made again. Not right here: the view tree
    /// should not change under the client while it is being read.
    override func accessibilityChildren() -> [Any]? {
        if !hasBeenAskedForAccessibility {
            hasBeenAskedForAccessibility = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pages.keys.forEach { self.removePage($0, parks: false) }
                self.unpark()
                self.buildPages()
            }
        }
        return super.accessibilityChildren()
    }

    /// Takes a page down and remembers how far its list was scrolled, unless it is the last
    /// visited island's, which is parked. Any other page only lives while its island is shown or
    /// kept warm next to the shown one. Coming back to such an island later makes a new list,
    /// which would start at the top.
    private func removePage(_ id: Island.ID?, parks: Bool = true) {
        guard let page = pages.removeValue(forKey: id) else { return }
        noteShown()
        if parks, let id, id == lastVisited {
            unpark()
            page.isHidden = true
            parked = (id, page)
            return
        }
        rememberScroll(of: id, in: page)
        page.removeFromSuperview()
    }

    /// Lets go of the parked page for good.
    private func unpark() {
        guard let (id, page) = parked else { return }
        parked = nil
        rememberScroll(of: id, in: page)
        page.removeFromSuperview()
    }

    private func noteShown() {
        let now = state.anchor ?? fallbackAnchor
        guard now != shown else { return }
        lastVisited = shown
        shown = now
    }

    /// The page for `id`: the parked one if it is that island's, a new one otherwise.
    private func page(for id: Island.ID?, content: (Island.ID?) -> AnyView) -> (page: NSHostingView<AnyView>, isNew: Bool) {
        guard let parked, parked.id == id else { return (addPage(id, content: content), true) }
        self.parked = nil
        parked.page.rootView = content(id)
        parked.page.isHidden = false
        pages[id] = parked.page
        return (parked.page, false)
    }

    private func rememberScroll(of id: Island.ID?, in page: NSView) {
        // A list that has not been scrolled back yet is still at the top, not where it belongs.
        guard let id, awaitingScroll[id] == nil, let list = Self.list(in: page),
              let table = list.documentView as? NSTableView
        else { return }
        let top = list.contentView.bounds.minY
        let row = table.row(at: NSPoint(x: table.bounds.midX, y: max(top, 0)))
        guard row >= 0 else {
            state.scrollAnchors[id] = nil
            return
        }
        state.scrollAnchors[id] = ListScrollAnchor(row: row, offset: top - table.rect(ofRow: row).minY)
    }

    /// Scrolls a new page's list back to where the island's last one was. SwiftUI may fill the
    /// list a pass or two after the page is made, and the list is shorter than it will be until
    /// the rows near its end have been measured, so this tries again for a few turns of the run
    /// loop before it settles for as far as it got.
    private func restoreScroll(of id: Island.ID?, in page: NSView, attempts: Int = 8) {
        guard let id, let anchor = state.scrollAnchors[id], pages[id] === page else { return }
        awaitingScroll[id] = anchor
        page.layoutSubtreeIfNeeded()
        if let list = Self.list(in: page), let table = list.documentView as? NSTableView, table.numberOfRows > anchor.row {
            let wanted = table.rect(ofRow: anchor.row).minY + anchor.offset
            let furthest = max(table.frame.height - list.contentView.bounds.height, 0)
            list.contentView.scroll(to: NSPoint(x: list.contentView.bounds.minX, y: min(wanted, furthest)))
            list.reflectScrolledClipView(list.contentView)
            if wanted <= furthest {
                awaitingScroll[id] = nil
                return
            }
        }
        guard attempts > 0 else {
            awaitingScroll[id] = nil
            return
        }
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page else { return }
            self.restoreScroll(of: id, in: page, attempts: attempts - 1)
        }
    }

    /// The scroll view of the page's list.
    private static func list(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return scroll }
        for subview in view.subviews {
            if let found = list(in: subview) { return found }
        }
        return nil
    }

    private func addPage(_ id: Island.ID?, content: (Island.ID?) -> AnyView) -> NSHostingView<AnyView> {
        let page = NSHostingView(rootView: content(id))
        // Sized by this view alone, and the sidebar's header and switcher already keep it
        // clear of the window's edges.
        page.sizingOptions = []
        page.safeAreaRegions = []
        addSubview(page)
        pages[id] = page
        return page
    }

    /// Puts `order` on screen with the state's motion right now, without waiting for the pager's
    /// update: that comes at the end of a pass in which the whole window changes, and the slide
    /// would only start after all of it. Only for a caller that has not changed the model yet,
    /// since the flush would otherwise run that whole pass itself. A page that is missing is
    /// built and laid out here, so the slide does not begin with an empty list.
    func showNow(order: [Island.ID]) {
        guard let content, window != nil else { return }
        let added = order.filter { pages[$0] == nil }.map { page(for: $0, content: content) }.filter(\.isNew).map(\.page)
        for id in pages.keys where !order.contains(where: { $0 == id }) {
            removePage(id)
        }
        self.order = order
        render()
        added.forEach { $0.layoutSubtreeIfNeeded() }
        for (id, page) in pages where added.contains(page) {
            restoreScroll(of: id, in: page)
        }
        CATransaction.flush()
    }

    func update(order: [Island.ID?], anchor: Island.ID?, islands: [Island.ID], crossfades: Bool, content: @escaping (Island.ID?) -> AnyView) {
        self.content = content
        wanted = (order, anchor, crossfades)
        // Its island was deleted, or Reduce Motion came on, which fades pages out and has no
        // use for one that is kept.
        if let parked, crossfades || !islands.contains(parked.id) { unpark() }
        buildPages()
    }

    private func buildPages() {
        // Not before the view is in its window: a page made earlier never shows up for
        // accessibility at all, whenever a client comes along.
        guard let content, let (order, anchor, crossfades) = wanted, window != nil else { return }
        let hadPages = !pages.isEmpty
        var added: [Island.ID?] = []
        for id in order {
            if let page = pages[id] {
                page.rootView = content(id)
                continue
            }
            let (page, isNew) = page(for: id, content: content)
            guard isNew else { continue }
            added.append(id)
            if crossfades, hadPages {
                page.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeDuration
                    page.animator().alphaValue = 1
                }
            }
        }
        for (id, page) in pages where !order.contains(id) {
            guard crossfades else {
                removePage(id)
                continue
            }
            pages[id] = nil
            rememberScroll(of: id, in: page)
            // Reduce Motion: it stays where it is and fades into the page that replaced it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                page.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { page.removeFromSuperview() }
            }
        }
        self.order = order
        fallbackAnchor = anchor
        render()
        // After the render, which is what gives a new page its size.
        for id in added {
            if let page = pages[id] { restoreScroll(of: id, in: page) }
        }
    }

    override func layout() {
        super.layout()
        state.width = bounds.width
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Out of the window nothing animates, and no spring would ever report that it ended.
        if window == nil {
            state.reset()
            state.fold()
        } else {
            buildPages()
        }
    }

    /// How far the springs under way have the strip moved on screen right now.
    var springOffset: Double {
        guard let layer, !springKeys.isEmpty, let shown = layer.presentation() else { return 0 }
        return shown.sublayerTransform.m41
    }

    /// Lays out the pages and shows the state's motion. The page frames depend on the anchor and
    /// the offset is measured from it, so both always change here, in one transaction.
    func render() {
        guard let layer, window != nil else { return }
        noteShown()
        let anchorIndex: Int
        if let index = order.firstIndex(of: state.anchor) {
            anchorIndex = index
        } else if let index = order.firstIndex(of: fallbackAnchor) {
            // The state moved on to an anchor whose page is not here yet. The pager is about to
            // bring it; until then what is on screen stays as it is.
            if let anchor = state.anchor, anchor != fallbackAnchor, hasLaidOut { return }
            anchorIndex = index
        } else {
            anchorIndex = 0
        }
        hasLaidOut = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // On whole pixels, so the text stays sharp while the strip is held.
        let scale = window?.backingScaleFactor ?? 2
        let held = (state.held * scale).rounded() / scale
        if shownFlight != state.flight {
            shownFlight = state.flight
            springKeys.forEach(layer.removeAnimation(forKey:))
            springKeys = []
        }

        // At rest the neighbours reach one point into view, each along the edge it will come in
        // from. A list that is entirely out of view has no rows yet and would make them only when
        // a switch brings it in, which costs that switch several frames before it can start. The
        // point they show is the empty margin beside their rows.
        let isAtRest = state.held == 0 && state.launching.isEmpty && springKeys.isEmpty
        for (index, id) in order.enumerated() {
            let slot = index - anchorIndex
            let peek = isAtRest ? CGFloat(-slot.signum()) : 0
            let frame = CGRect(x: CGFloat(slot) * bounds.width + held + peek, y: 0, width: bounds.width, height: bounds.height)
            if let page = pages[id], page.frame != frame { page.frame = frame }
        }

        let flight = state.flight
        for spring in state.launching {
            let animation = CAKeyframeAnimation(keyPath: "sublayerTransform.translation.x", adding: spring)
            let key = "spring-\(nextSpringKey)"
            nextSpringKey += 1
            animation.delegate = AnimationEnd { [weak self] finished in
                guard let self else { return }
                self.springKeys.removeAll { $0 == key }
                if finished { self.state.landed(flight: flight) }
                if self.springKeys.isEmpty { self.render() }
            }
            layer.add(animation, forKey: key)
            springKeys.append(key)
        }
        state.didLaunch()
    }
}

extension CAKeyframeAnimation {
    /// Plays `spring` on top of the layer's value and of the animations already running on it.
    /// The layer is set to where it should end up; the spring is how far from there it still is.
    convenience init(keyPath: String, adding spring: PageSpring) {
        self.init(keyPath: keyPath)
        let positions = spring.trajectory()
        values = positions
        duration = Double(positions.count - 1) / PageSpring.sampleRate
        calculationMode = .linear
        isAdditive = true
    }
}

private final class AnimationEnd: NSObject, CAAnimationDelegate {
    private let ended: @MainActor (_ finished: Bool) -> Void

    init(ended: @escaping @MainActor (_ finished: Bool) -> Void) {
        self.ended = ended
    }

    /// Replaced or dropped animations stop too, without having finished.
    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        MainActor.assumeIsolated { ended(finished) }
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
        // Switches come in twice: from the model right before they are made, and from here once
        // SwiftUI updates. The second is a no-op then, and the only one for a change of island
        // that is not a switch, like the selected island being deleted.
        .onChange(of: model.selectedIsland?.id) { old, new in enter(from: old, to: new) }
        .onChange(of: isEnabled, initial: true) {
            watchSwitches()
            if !isEnabled { rest(at: model.selectedIsland?.id) }
        }
        .onChange(of: reduceMotion, initial: true) { watchSwitches() }
    }

    /// Installed again whenever what `enter` reads from this view changes: the closure keeps the
    /// view as it was when it was made.
    private func watchSwitches() {
        model.islandWillSwitch = { old, new in enter(from: old, to: new, startsNow: true) }
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
            state.strip = state.swipeStrip
            state.anchor = currentAnchor
            // A strip caught already past halfway does not announce it.
            var caught = gesture
            caught.headStart = state.headStart
            state.isPastCommitPoint = caught.isPastCommitPoint
        }
        var gesture = gesture
        gesture.headStart = state.headStart
        // One tick on the way past halfway: from here, letting go switches. The switch itself
        // has none, since the fingers have left the trackpad by then.
        if gesture.isPastCommitPoint, !state.isPastCommitPoint { Haptics.levelChange() }
        state.isPastCommitPoint = gesture.isPastCommitPoint
        guard !reduceMotion else { return }
        state.follow(gesture.offset)
    }

    private func release(_ gesture: IslandSwipe) {
        guard state.ownsGesture, state.swipeGeneration == state.generation else { return }
        state.ownsGesture = false
        var gesture = gesture
        gesture.headStart = state.headStart
        let strip = state.swipeStrip
        let target = gesture.settledIndex()
        guard target != gesture.selectedIndex, strip.indices.contains(target) else {
            reduceMotion ? rest(at: currentAnchor) : state.settle(velocity: gesture.contentVelocity, response: IslandSwipeState.swipeResponse)
            return
        }
        let id = strip[target]
        if reduceMotion {
            crossfade(to: id)
            model.select(island: id)
            return
        }
        // Re-anchor on the target. Nothing moves on screen, but selecting now lets the switcher
        // and the window update while the strip is still settling.
        state.reanchor(to: id, shift: Double(target - gesture.selectedIndex) * state.width)
        state.settle(velocity: gesture.contentVelocity, response: IslandSwipeState.dropResponse)
        // Selecting keeps the main thread busy for several frames. Sent off first, the settle
        // starts at the speed the fingers had, without the strip standing still in between.
        CATransaction.flush()
        model.select(island: id)
    }

    // MARK: Switches

    /// Shortcuts, menu items, clicks and session jumps change the island without a swipe. The old
    /// list is still on screen when this runs, so both slide together: the old one out, the new one
    /// in. A switch that comes while the strip is still moving adds to the motion under way.
    ///
    /// With `startsNow` the switch is yet to be made, and the slide is sent to the screen ahead of
    /// it instead of with the next update, which only gets there after the new island's content.
    private func enter(from old: Island.ID?, to new: Island.ID?, startsNow: Bool = false) {
        // Already on its way there: a swipe made the switch and moves the strip itself, or this
        // switch was started before it was made.
        if state.anchor == new { return }
        // A swipe in progress loses the strip to the switch; its remaining events are dropped.
        state.generation += 1
        state.ownsGesture = false
        let islands = model.workspace.islands
        guard isEnabled, let new, islands.contains(where: { $0.id == new }) else {
            rest(at: new)
            return
        }
        // A click on the switcher is felt. A swipe never gets here: it has its tick at halfway.
        Haptics.levelChange()
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
        state.strip = strip
        state.reanchor(to: new, shift: shift)
        state.settle(velocity: 0, response: IslandSwipeState.switchResponse)
        if startsNow { state.surface?.showNow(order: strip) }
        state.switched()
    }

    /// Reduce Motion: no sliding. The strip view fades the lists into each other in place.
    private func crossfade(to id: Island.ID) {
        state.strip = []
        state.anchor = id
        state.reset()
    }

    private func rest(at id: Island.ID?) {
        state.ownsGesture = false
        state.strip = []
        state.anchor = id
        state.reset()
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
