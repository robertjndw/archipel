import InspectorUI
import SwiftUI

/// Shared measurements for the window chrome, so the tab rows, their toolbar
/// groups and the palette keep the same rhythm.
///
/// `panelRadius` and `controlRadius` are the app's two corner radii. The packages cannot see this
/// enum, so `CornerRadius` in UISupport holds the same two values; keep them in step.
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
    /// The room around each pane in this style: the top line's distance from the window's top
    /// edge, and how far the status bar reaches up into the cards' bottom gap. The gap and the bar
    /// together are the strip under the cards, whose middle is the bottom line.
    static func paneGap(for style: AppSettings.PaneStyle) -> CGFloat {
        style == .comfortable ? paneGap : 0
    }
    /// Corner radius of a pane: concentric with the window's corners, which sit `paneGap` away
    /// from the outer cards. Square in the compact style. Only the peek's zoom card uses it, to
    /// have a number to animate to. The panes themselves are a `PaneShape`.
    static func paneRadius(for style: AppSettings.PaneStyle, windowRadius: CGFloat) -> CGFloat {
        style == .comfortable ? concentricRadius(windowRadius, inset: paneGap) : 0
    }
    /// For the peek's zoom card, which animates its radius and so cannot be a `PaneShape`.
    /// Circular comes closer to that shape than continuous does.
    static let paneCornerStyle: RoundedCornerStyle = .circular
    /// Opacity of the white hairline inside a pane's edge. AppKit draws a similar one along the
    /// window edge. Against a black terminal it smooths out the stair steps of the corner on 1x
    /// displays; on light content you don't see it.
    static let paneEdgeOpacity: Double = 0.08
    /// Radius for a shape nested `inset` inside a corner of `radius`. Clamped to 4pt so it never
    /// turns square.
    static func concentricRadius(_ radius: CGFloat, inset: CGFloat) -> CGFloat {
        max(radius - inset, 4)
    }
    /// How far a file, diff or web pane without focus fades into its own background.
    /// Matches Ghostty's default unfocused-split-opacity of 0.7, which terminals follow.
    static let unfocusedPaneDim: Double = 0.3
    /// The one surface of the window around the content: between the panes, under the status bar,
    /// and in the inspector, which paints the same measured color.
    static let windowSurface = Color.inspectorBackground
    /// Corner radius of small controls that stand on their own: selection fills in lists, search
    /// fields, the symbol picker's cells, the settings tiles' rings. A shape nested inside one of
    /// these takes this minus its inset, so the two stay concentric.
    static let controlRadius: CGFloat = 8

    /// Height of the controls on the bottom line, the island switcher's capsule among them: the
    /// small control size.
    static let bottomControlHeight: CGFloat = 22

    /// The middle of the window's bottom line, from its bottom edge: the status bar's items, the
    /// island switcher and its new island button. The strip under the cards is twice this, 30pt,
    /// which leaves a small control 4pt above and below.
    static let bottomLineInset: CGFloat = 15
}

/// The outline of a pane card: the window's outline moved inward by `gap`, so the band between
/// the card and the window edge is the same width all the way round the corner.
///
/// A rounded rectangle with the window's radius minus the gap does not give that. The window
/// corner is a continuous curve and starts to turn well before a circle would, so a circular
/// corner inside it makes the band thinner where the turn begins. It is only about a quarter of
/// a point, but on a 1x display you can see it.
nonisolated struct PaneShape: Shape {
    enum Part {
        case card
        /// A 1pt line just inside the card's edge.
        case edge
        /// The four corner slivers between the card and its bounds.
        case surround
    }

    var windowRadius: CGFloat
    var gap: CGFloat
    var part = Part.card

    func path(in rect: CGRect) -> Path {
        // Compact panes touch the window edge and each other, so they stay square.
        guard gap > 0 else { return part == .card ? Path(rect) : Path() }
        let window = RoundedRectangle(cornerRadius: windowRadius, style: .continuous)
            .path(in: rect.insetBy(dx: -gap, dy: -gap))
        let card = window.subtracting(window.strokedPath(StrokeStyle(lineWidth: gap * 2, lineJoin: .round)))
        switch part {
        case .card: return card
        case .edge: return card.intersection(card.strokedPath(StrokeStyle(lineWidth: 2, lineJoin: .round)))
        case .surround: return Path(rect).subtracting(card)
        }
    }
}

extension View {
    /// For a sheet's Cancel button and other plain buttons and menus in sheets. The window's island
    /// tint reaches into sheets, and `tint` colors the text of every bordered button and menu,
    /// where the system's accent color only fills the default button. Without this, Cancel reads
    /// as the action to take.
    func untinted() -> some View {
        tint(nil)
    }
}

/// The curves the chrome shares. The package has the same enum in UISupport, which the app target
/// cannot import without a project change; keep the values in step.
enum Motion {
    /// A selection pill sliding between items. A slight bounce so it settles onto the new item.
    static let selection = Animation.spring(duration: 0.35, bounce: 0.15)
    /// Hover highlights and the reveal of hover-only controls.
    static let hover = Animation.easeOut(duration: 0.15)
    /// The island switcher's labels. Matches the spring the sidebar strip uses for a shortcut or a
    /// click (same response and damping), so the labels and the lists arrive together.
    static let page = Animation.spring(duration: 0.25, bounce: 0.1)
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
