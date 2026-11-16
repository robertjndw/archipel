import AppKit

/// Hands the keyboard to the editor of a given file. The host calls this after opening a file from the
/// keyboard (Open Quickly, the Go to palette), where the user expects to type straight away.
///
/// The request is kept for a moment rather than applied once, because the editor may not exist yet:
/// the file loads asynchronously and only then is its text view created. An already open editor
/// answers through the notification instead.
@MainActor
public enum EditorFocus {
    private static var pending: (url: URL, deadline: ContinuousClock.Instant)?
    static let requested = Notification.Name("EditorFocus.requested")

    public static func request(_ url: URL) {
        pending = (url.standardizedFileURL, .now + .seconds(2))
        NotificationCenter.default.post(name: requested, object: nil)
    }

    /// True once for the editor the pending request is for; the request is used up so a later editor
    /// of the same file does not steal focus.
    static func claim(_ url: URL) -> Bool {
        guard let pending, pending.url == url.standardizedFileURL else { return false }
        self.pending = nil
        return ContinuousClock.now < pending.deadline
    }
}
