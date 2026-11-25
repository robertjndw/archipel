import CoreGraphics

/// The two corner radii the app is built from, so every surface has one of two shapes. Anything
/// nested inside one of them takes that radius minus its inset, which keeps the two concentric.
/// The app target cannot import UISupport without a project change, so `Chrome` in the app holds
/// the same values as `controlRadius` and `panelRadius`; keep them in step.
public enum CornerRadius {
    /// Small shapes that stand on their own: selection and hover fills, code blocks, fields.
    public static let control: CGFloat = 8
    /// Floating glass surfaces: the command palette, the chat's composer and its cards.
    public static let panel: CGFloat = 20

    /// Radius for a shape nested `inset` inside a corner of `radius`. Clamped to 4pt so it never
    /// turns square.
    public static func concentric(_ radius: CGFloat, inset: CGFloat) -> CGFloat {
        max(radius - inset, 4)
    }
}
