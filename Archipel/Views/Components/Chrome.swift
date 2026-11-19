import InspectorUI
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
    /// Room around each pane in the comfortable pane style. Between two panes the gap is this plus
    /// the 1pt split divider, which stays there to be dragged.
    static let paneGap: CGFloat = 6
    /// The smallest corner radius of a pane in the comfortable pane style. Panes use a
    /// `ConcentricRectangle`, so a corner next to the window's own corner follows that one instead.
    /// The window's corners measure about 16pt on macOS 27, and 16 minus the 6pt gap gives 10, so
    /// the corners agree whether or not the system resolves the concentric shape.
    static let paneRadius: CGFloat = 10
    /// How far a file, diff or web pane without focus fades into its own background.
    /// Matches Ghostty's default unfocused-split-opacity of 0.7, which terminals follow.
    static let unfocusedPaneDim: Double = 0.3
    /// The one surface of the window around the content: between the panes, under the status bar,
    /// and in the inspector, which paints the same measured color.
    static let windowSurface = Color.inspectorBackground
}

/// The curves the chrome shares. The package has the same enum in UISupport, which the app target
/// cannot import without a project change; keep the values in step.
enum Motion {
    /// A selection pill sliding between items. A slight bounce so it settles onto the new item.
    static let selection = Animation.spring(duration: 0.35, bounce: 0.15)
    /// Hover highlights and the reveal of hover-only controls.
    static let hover = Animation.easeOut(duration: 0.15)
    /// Expanding and collapsing a section in place.
    static let disclosure = Animation.snappy(duration: 0.2)
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
                // Monochrome like the buttons over the sidebar; the accent color stays with the content.
                .foregroundStyle(.secondary)
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

#if DEBUG
private func previewToolbarGroups() -> some View {
    VStack(alignment: .leading, spacing: 12) {
        GlassToolbarGroup {
            Button("Show Sidebar", systemImage: "sidebar.left") {}
        }
        GlassToolbarGroup {
            Menu {
                Button("Claude Code") {}
                Button("Shell") {}
            } label: {
                Image(systemName: "plus")
            }
            .toolbarGroupMenu()
            Button("Run", systemImage: "play") {}
            Button("Hide Inspector", systemImage: "sidebar.trailing") {}
        }
    }
    .padding(20)
    .background(.windowBackground)
}

#Preview {
    HStack(spacing: 0) {
        previewToolbarGroups()
        previewToolbarGroups()
            .environment(\.colorScheme, .dark)
    }
}
#endif
