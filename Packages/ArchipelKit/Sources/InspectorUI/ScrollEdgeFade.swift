import SwiftUI

extension View {
    /// Fades the top or bottom edge while content is cut off there. Replaces the system scroll edge
    /// effect, which needs a bar, and bars show a hairline on hover.
    func scrollEdgeFade(height: CGFloat = 28) -> some View {
        modifier(ScrollEdgeFade(height: height))
    }
}

private struct ScrollEdgeFade: ViewModifier {
    let height: CGFloat
    @State private var clipped = ClippedEdges()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct ClippedEdges: Equatable {
        var top = false
        var bottom = false
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ClippedEdges.self) { geometry in
                // Half a point of slack so rubber-banding and rounding do not flicker the fade.
                let top = geometry.contentOffset.y + geometry.contentInsets.top > 0.5
                let bottom = geometry.visibleRect.maxY < geometry.contentSize.height - 0.5
                return ClippedEdges(top: top, bottom: bottom)
            } action: { _, edges in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { clipped = edges }
            }
            // An overlay rather than a mask: masking the sidebar-style list makes its icons vanish.
            .overlay(alignment: .top) { fade(from: .top).opacity(clipped.top ? 1 : 0) }
            .overlay(alignment: .bottom) { fade(from: .bottom).opacity(clipped.bottom ? 1 : 0) }
    }

    private func fade(from edge: VerticalEdge) -> some View {
        let background = Color.inspectorBackground
        // Solid for the first 30% so rows don't show half transparent right below the header.
        return LinearGradient(
            stops: [
                .init(color: background, location: 0),
                .init(color: background, location: 0.3),
                .init(color: background.opacity(0), location: 1),
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: height)
        .allowsHitTesting(false)
    }
}
