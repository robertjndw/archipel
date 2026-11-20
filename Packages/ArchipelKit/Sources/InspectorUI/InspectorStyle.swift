import AppKit
import SwiftUI

extension View {
    /// The sidebar list style sizes its rows from the system "Sidebar icon size"
    /// setting, whose default is too roomy for a file tree. Pin it to the small
    /// size, which is what Xcode's navigators use.
    func compactRows() -> some View {
        environment(\.sidebarRowSize, .small)
    }
}

extension Color {
    /// Painted by the inspector so the scroll fades can use the exact same color. No system color or
    /// material matched the inspector background in both light and dark mode on macOS 26, so these
    /// values are measured. A fade in any other color shows up as a band.
    ///
    /// Public because the app paints the rest of its window surface (the room between the panes
    /// and the status bar) in it too, so the inspector and the space around the panes match.
    public static let inspectorBackground = Color(nsColor: NSColor(name: "InspectorBackground") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let level: CGFloat = (isDark ? 47 : 239) / 255
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    })
}
