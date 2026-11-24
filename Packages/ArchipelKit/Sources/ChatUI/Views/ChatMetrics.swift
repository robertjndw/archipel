import SwiftUI
import UISupport

/// Shared measurements of the chat, so the transcript, the cards above the composer and the
/// composer keep one rhythm.
enum ChatMetrics {
    /// The reading column. Wide enough for code, narrow enough that prose lines stay readable.
    static let columnWidth: CGFloat = 720
    /// The composer while nothing has been said yet, when it sits in the middle of the pane.
    static let welcomeComposerWidth: CGFloat = 560
    /// Corner radius of the composer, the cards docked above it and the user's own messages: the
    /// app's panel radius, so the chat's surfaces have the shape of the palette's.
    static let surfaceRadius = CornerRadius.panel
    /// Corner radius of blocks inside the transcript and of hover fills: the app's control radius,
    /// which Markdown code blocks use too.
    static let blockRadius = CornerRadius.control
    /// Width of the symbol column of tool and thought rows; their details indent by this much.
    static let symbolColumn: CGFloat = 18
    static let symbolSpacing: CGFloat = 6
    static let activityRowHeight: CGFloat = 26
    /// Room under a finished reply for the Copy button. Matches the status line that stood there
    /// during the turn, so nothing moves when one replaces the other.
    static let replyFooterHeight: CGFloat = 26
    /// Line height of 12pt monospaced text in output and diff blocks. Fixed so tinted diff lines,
    /// which are drawn apart from the text, land exactly behind it.
    static let codeLineHeight: CGFloat = 17
    static let codeFontSize: CGFloat = 12

    /// Room between the column and the pane's edges. A narrow pane gives most of it up.
    static func gutter(forPaneWidth width: CGFloat) -> CGFloat {
        width < 560 ? 14 : 24
    }

    static var detailIndent: CGFloat { symbolColumn + symbolSpacing }
    static var codeFont: Font { .system(size: codeFontSize, design: .monospaced) }
}

extension EnvironmentValues {
    @Entry var chatGutter: CGFloat = 24
    /// The agent's logo. The app owns the artwork, so it arrives as a value.
    @Entry var chatAgentSymbol = Image(systemName: "sparkles")
    /// The session's working directory, which paths are shown relative to. Nil in previews.
    @Entry var chatWorkingDirectory: String?
    /// The agent's name as the user knows it. Per-agent state such as favorite models is stored
    /// under it. Nil outside a chat.
    @Entry var chatAgentName: String?
    /// False while the composer has text or a permission card is docked there, so tips stay away.
    @Entry var composerHasRoomForTips = true
    /// The chat's diffs; nil outside a chat, where `DiffCache.fallback` stands in. Optional so the
    /// default is not a new cache on every read.
    @Entry var chatDiffCache: DiffCache?
}

extension View {
    /// Centers the view in the reading column, with the pane's gutter on both sides.
    func chatColumn(maxWidth: CGFloat = ChatMetrics.columnWidth) -> some View {
        modifier(ChatColumn(maxWidth: maxWidth))
    }
}

private struct ChatColumn: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.chatGutter) private var gutter

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, gutter)
            .frame(maxWidth: .infinity)
    }
}

/// Gives its one subview, a scroll view, the height of its content up to a maximum.
///
/// `frame(maxHeight:)` does not do this: a scroll view takes whatever height it is offered, so it
/// would always be as tall as the maximum, with two lines of content as with two hundred.
struct CappedHeight: Layout {
    var maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maximum))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
