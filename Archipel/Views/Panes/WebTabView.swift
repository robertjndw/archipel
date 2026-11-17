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
        if let page = model.webPages.page(for: tabID, url: url) {
            VStack(spacing: 0) {
                WebToolbar(page: page, fallbackURL: url)
                Divider()
                WebView(page)
                    .webViewBackForwardNavigationGestures(.enabled)
            }
            // A reused preview tab gets a new page; this swaps the WebView along with it.
            .id(ObjectIdentifier(page))
        } else {
            // The model opens the page when the tab comes on screen, so this is not normally seen.
            // Should a tab get here without one, it is opened after this update instead of during it.
            Color.clear
                .task(id: url) { model.webPages.open(tabID, url: url) }
        }
    }
}

private struct WebToolbar: View {
    let page: WebPage
    /// Shown until the page reports a URL of its own.
    let fallbackURL: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shownURL = page.url ?? fallbackURL
        HStack(spacing: 4) {
            Button("Back", systemImage: "chevron.backward") {
                if let item = page.backForwardList.backList.last { _ = page.load(item) }
            }
            .disabled(page.backForwardList.backList.isEmpty)
            .help("Back")

            Button("Forward", systemImage: "chevron.forward") {
                if let item = page.backForwardList.forwardList.first { _ = page.load(item) }
            }
            .disabled(page.backForwardList.forwardList.isEmpty)
            .help("Forward")

            // One button whose symbol is replaced, so the swap can animate instead of cutting.
            Button(
                page.isLoading ? "Stop" : "Reload",
                systemImage: page.isLoading ? "xmark" : "arrow.clockwise"
            ) {
                if page.isLoading { page.stopLoading() } else { _ = page.reload() }
            }
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : Motion.hover, value: page.isLoading)
            .help(page.isLoading ? "Stop Loading" : "Reload")

            Text(shownURL.absoluteString)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(shownURL) }
                .help("Open in Browser")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.hover, value: page.isLoading)
    }
}
