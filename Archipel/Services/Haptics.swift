import AppKit

/// Trackpad feedback in one place. The system drops these silently when there is no Force Touch
/// trackpad or the user turned haptics off, so callers never need to check.
enum Haptics {
    /// Something clicked into place, like a divider reaching the middle.
    static func alignment() {
        perform(.alignment)
    }

    /// A discrete step from one state to the next, like landing on another island or tab slot.
    static func levelChange() {
        perform(.levelChange)
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
