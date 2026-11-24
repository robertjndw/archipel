import Foundation

public enum TabContent: Codable, Hashable, Sendable {
    case session(Session.ID)
    case file(URL)
    /// `path` is relative to the worktree root.
    case diff(path: String, staged: Bool)
    /// The page first opened. Navigating inside the tab doesn't change it, so opening that URL
    /// again finds this tab.
    case web(URL)
}

public struct Tab: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var content: TabContent
    /// A preview tab is reused by the next preview open, like a single-clicked file in VS Code. Session tabs are never previews.
    public var isPreview: Bool

    public init(id: UUID = UUID(), content: TabContent, isPreview: Bool = false) {
        self.id = id
        self.content = content
        self.isPreview = isPreview
    }
}

public struct Pane: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var tabs: [Tab]
    public var selectedTabID: Tab.ID?
    /// The pane's part of the worktree's width, as a fraction of 1. Nil until a divider is dragged,
    /// and again whenever a pane is added or closed, which gives every pane the same width. Either
    /// all panes of a worktree have one or none does; read them through `Worktree.paneWidthShares`.
    public var widthShare: Double?

    public init(id: UUID = UUID(), tabs: [Tab] = [], selectedTabID: Tab.ID? = nil, widthShare: Double? = nil) {
        self.id = id
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.widthShare = widthShare
    }

    /// The stored selection if it exists, otherwise the first tab.
    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }
}
