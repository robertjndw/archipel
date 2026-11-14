import Foundation

/// Tabs (sessions, files and diffs) in the order the user last had them in front, most recent
/// first. Drives Ctrl-Tab.
public struct RecentTabs: Equatable, Sendable {
    public private(set) var ids: [Tab.ID]

    /// Far more than the switcher shows. Only there so the stored list can't grow forever.
    public static let capacity = 50

    public init(ids: [Tab.ID] = []) {
        var seen = Set<Tab.ID>()
        self.ids = Array(ids.filter { seen.insert($0).inserted }.prefix(Self.capacity))
    }

    public mutating func visit(_ id: Tab.ID) {
        guard ids.first != id else { return }
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.capacity { ids.removeLast(ids.count - Self.capacity) }
    }

    /// What the switcher lists: recent tabs that are still open, then open tabs that were never
    /// visited but pass `includesUnvisited` (a session running in the background, say), in
    /// workspace order.
    public func candidates(in workspace: Workspace, includesUnvisited: (Tab) -> Bool, limit: Int) -> [Tab.ID] {
        let open = workspace.allWorktrees.flatMap { $0.panes.flatMap(\.tabs) }
        let openIDs = Set(open.map(\.id))
        var result = ids.filter(openIDs.contains)
        var listed = Set(result)
        for tab in open where includesUnvisited(tab) && listed.insert(tab.id).inserted {
            result.append(tab.id)
        }
        return Array(result.prefix(limit))
    }
}

/// One Ctrl-Tab gesture, from the first press until Control is let go.
public struct TabSwitch: Equatable, Sendable {
    public let candidates: [Tab.ID]
    public private(set) var selection: Int

    /// Starts on the tab to switch to: the one before the current, or the most recent one when the
    /// current tab is not among the candidates, so a single tap always goes somewhere. Nil when
    /// there is nowhere to go.
    public init?(candidates: [Tab.ID], current: Tab.ID?) {
        let start = candidates.first == current && current != nil ? 1 : 0
        guard candidates.indices.contains(start) else { return nil }
        self.candidates = candidates
        selection = start
    }

    public var selectedID: Tab.ID { candidates[selection] }

    /// Wraps around both ends, like the app switcher.
    public mutating func advance(by offset: Int) {
        let count = candidates.count
        selection = ((selection + offset) % count + count) % count
    }

    public mutating func select(_ id: Tab.ID) {
        if let index = candidates.firstIndex(of: id) { selection = index }
    }
}
