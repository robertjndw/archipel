import AppKit
import ArchipelCore
import SwiftUI
import WebKit

/// A web page in a tab, with back, forward and reload.
struct WebTabView: View {
    @Environment(AppModel.self) private var model
    let tabID: ArchipelCore.Tab.ID
    let url: URL

    var body: some View {
        let page = model.webPages.page(for: tabID, url: url)
        VStack(spacing: 0) {
            WebToolbar(page: page, fallbackURL: url)
            Divider()
            WebView(page)
                .webViewBackForwardNavigationGestures(.enabled)
        }
        // A reused preview tab gets a new page; this swaps the WebView along with it.
        .id(ObjectIdentifier(page))
    }
}

private struct WebToolbar: View {
    let page: WebPage
    /// Shown until the page reports a URL of its own.
    let fallbackURL: URL

    var body: some View {
        let shownURL = page.url ?? fallbackURL
        HStack(spacing: 4) {
            Button("Back", systemImage: "chevron.backward") {
                if let item = page.backForwardList.backList.last { _ = page.load(item) }
            }
            .disabled(page.backForwardList.backList.isEmpty)

            Button("Forward", systemImage: "chevron.forward") {
                if let item = page.backForwardList.forwardList.first { _ = page.load(item) }
            }
            .disabled(page.backForwardList.forwardList.isEmpty)

            if page.isLoading {
                Button("Stop", systemImage: "xmark") { page.stopLoading() }
            } else {
                Button("Reload", systemImage: "arrow.clockwise") { _ = page.reload() }
            }

            Text(shownURL.absoluteString)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(shownURL) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
        }
    }
}
