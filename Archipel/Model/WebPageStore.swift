import ArchipelCore
import Foundation
import WebKit

/// The live page of each web tab. Kept outside the view, like `FileDocumentStore`, so switching
/// tabs doesn't reload the page and lose its history and scroll position.
@MainActor
final class WebPageStore {
    private var pages: [Tab.ID: (url: URL, page: WebPage)] = [:]

    /// A preview tab can be reused for another URL, which then gets a fresh page.
    func page(for tab: Tab.ID, url: URL) -> WebPage {
        if let entry = pages[tab], entry.url == url { return entry.page }
        let page = WebPage()
        _ = page.load(URLRequest(url: url))
        pages[tab] = (url, page)
        return page
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
