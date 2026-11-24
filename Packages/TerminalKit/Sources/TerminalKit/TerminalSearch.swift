import Observation

/// Scrollback search in one session. Ghostty owns the search and reports
/// matches back; the host shows a field while `isActive` and edits `needle`.
@MainActor
@Observable
public final class TerminalSearch {
    /// Ghostty asked for a search field (Cmd-F by default) and has not ended it.
    public private(set) var isActive = false
    /// Number of matches, nil until Ghostty has counted them.
    public private(set) var total: Int?
    /// Zero-based index of the highlighted match, nil when none is highlighted.
    public private(set) var selected: Int?
    /// Bumped whenever Ghostty asks for the field again while it is open, so
    /// the host can take keyboard focus back from the terminal.
    public private(set) var focusRequests = 0

    public var needle = "" {
        didSet { if needle != oldValue { scheduleSearch() } }
    }

    @ObservationIgnored private weak var view: SurfaceView?
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    /// Whether Ghostty has a needle. It refuses to stop or step through a
    /// search it does not have, and logs each refusal.
    @ObservationIgnored private var searching = false
    /// A request for the field that no field has answered yet.
    @ObservationIgnored private var awaitsFocus = false

    init(view: SurfaceView) {
        self.view = view
    }

    public func next() { navigate("navigate_search:next") }
    public func previous() { navigate("navigate_search:previous") }

    /// Ends the search and gives the keyboard back to the terminal.
    public func close() {
        if let view, view.surface != nil {
            // Ghostty answers with END_SEARCH, which lands in `ended()`.
            view.performBinding("end_search")
            view.window?.makeFirstResponder(view)
        } else {
            ended()
        }
    }

    /// True once per request for the field. The field asks when it appears and when
    /// `focusRequests` changes, and takes the keyboard only on a yes: the search stays open
    /// while its terminal leaves the screen, and a field that merely came back with it must
    /// not pull the keyboard away from wherever it is by then.
    public func takeFocusRequest() -> Bool {
        defer { awaitsFocus = false }
        return awaitsFocus
    }

    func started(needle: String?) {
        isActive = true
        if let needle, !needle.isEmpty { self.needle = needle }
        awaitsFocus = true
        focusRequests += 1
    }

    func ended() {
        // Cleared before the needle so the reset does not start a new search.
        isActive = false
        awaitsFocus = false
        pendingSearch?.cancel()
        pendingSearch = nil
        searching = false
        needle = ""
        total = nil
        selected = nil
    }

    func update(total: Int?) {
        guard isActive else { return }
        self.total = total
    }

    func update(selected: Int?) {
        guard isActive else { return }
        self.selected = selected
    }

    /// Every needle restarts Ghostty's search over the whole scrollback, and
    /// one or two characters match almost everywhere, so short needles wait
    /// for the next keystroke the way upstream's search bar does.
    private func scheduleSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        guard isActive else { return }
        if needle.isEmpty || needle.count >= 3 {
            sendNeedle()
            return
        }
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.sendNeedle()
        }
    }

    private func sendNeedle() {
        pendingSearch = nil
        guard !needle.isEmpty || searching else { return }
        // An empty needle stops the search but keeps the field, which is what
        // clearing the field should do.
        searching = !needle.isEmpty
        if !searching {
            total = nil
            selected = nil
        }
        view?.performBinding("search:\(needle)")
    }

    private func navigate(_ action: String) {
        // Return right after typing must not step through stale matches.
        if pendingSearch != nil {
            pendingSearch?.cancel()
            sendNeedle()
        }
        guard searching else { return }
        view?.performBinding(action)
    }
}
