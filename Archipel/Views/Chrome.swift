import SwiftUI

/// Shared measurements for the window chrome, so the tab rows, their toolbar
/// groups and the palette keep the same rhythm.
enum Chrome {
    /// Height of a toolbar group and of a tab in the pane tab row. Leaves 4pt
    /// above and below inside `PaneTabBar.height` for the glass shadow.
    static let controlHeight: CGFloat = 28
    /// Corner radius of the command palette. Rows inside it are inset so their
    /// own radius stays concentric with it.
    static let panelRadius: CGFloat = 20
}

/// Icon buttons sharing one glass capsule, the way a toolbar group looks in
/// Xcode and Finder. The buttons themselves stay borderless: a glass button
/// inside a glass group would stack glass on glass.
struct GlassToolbarGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: Chrome.controlHeight + 4, height: Chrome.controlHeight)
                .contentShape(.rect)
        }
        .padding(.horizontal, 2)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

extension View {
    /// Pins a menu inside a `GlassToolbarGroup` to the same square as the
    /// buttons next to it, without the menu's own chrome.
    func toolbarGroupMenu() -> some View {
        menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
