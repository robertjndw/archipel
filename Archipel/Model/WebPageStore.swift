import ArchipelCore
import Foundation
import Observation
import WebKit

/// The live page of each web tab. Kept outside the view, like `FileDocumentStore`, so switching
/// tabs doesn't reload the page and lose its history and scroll position.
///
/// Observed, so a tab's title appears when its page is created and not only once something else
/// redraws the tab bar.
@MainActor @Observable
final class WebPageStore {
    private var pages: [Tab.ID: (url: URL, page: WebPage)] = [:]

    /// Creates and starts loading the tab's page unless it has one for that URL. The model calls
    /// this when a web tab comes on screen, so the view's `page(for:url:)` only has to look it up:
    /// creating it there would change what other views observe while they are being updated.
    /// A preview tab can be reused for another URL, which then gets a fresh page.
    func open(_ tab: Tab.ID, url: URL) {
        if let entry = pages[tab], entry.url == url { return }
        let page = WebPage()
        _ = page.load(URLRequest(url: url))
        pages[tab] = (url, page)
    }

    /// The tab's page if it has one for that URL. Never creates one, so a view body can call it.
    func page(for tab: Tab.ID, url: URL) -> WebPage? {
        guard let entry = pages[tab], entry.url == url else { return nil }
        return entry.page
    }

    /// Whatever page the tab shows right now, for commands that act on the focused tab.
    func page(for tab: Tab.ID) -> WebPage? {
        pages[tab]?.page
    }

    /// The page's own title once it has loaded one.
    func title(for tab: Tab.ID) -> String? {
        guard let title = pages[tab]?.page.title, !title.isEmpty else { return nil }
        return title
    }

    /// Drops the pages of tabs that are gone or no longer show a web page. A page keeps playing
    /// media and running scripts for as long as it is held.
    func retain(only tabs: Set<Tab.ID>) {
        for id in pages.keys where !tabs.contains(id) {
            pages[id]?.page.stopLoading()
            pages[id] = nil
        }
    }
}
