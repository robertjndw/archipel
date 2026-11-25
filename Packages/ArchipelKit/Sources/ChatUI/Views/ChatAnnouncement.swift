import SwiftUI

/// Says something to VoiceOver that no element under its cursor would: a list that opened over
/// the composer, the result of a search typed into a field the cursor never leaves.
enum ChatAnnouncement {
    /// Ahead of what is being spoken, such as the echo of the key that caused it, which would
    /// otherwise finish first and often be all that is heard.
    @MainActor
    static func post(_ text: String) {
        guard !text.isEmpty else { return }
        var message = AttributedString(text)
        message.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(message).post()
    }
}
