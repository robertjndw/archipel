import SwiftUI

/// The few curves the app's chrome shares, so the same kind of movement feels the same everywhere.
/// The app target cannot import UISupport without a project change, so it keeps a twin of this
/// enum in Chrome.swift; keep the values in step.
public enum Motion {
    /// A selection pill sliding between items. A slight bounce so it settles onto the new item.
    public static let selection = Animation.spring(duration: 0.35, bounce: 0.15)
    /// Hover highlights and the reveal of hover-only controls.
    public static let hover = Animation.easeOut(duration: 0.15)
    /// Expanding and collapsing a section in place.
    public static let disclosure = Animation.snappy(duration: 0.2)
}
