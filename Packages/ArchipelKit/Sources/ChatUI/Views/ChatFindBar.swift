import AppKit
import SwiftUI
import UISupport

/// What a key in the find field does.
enum FindKeyAction: Equatable, Sendable {
    case next
    case previous
    case close
}

/// The find field's keys and what the bar says next to it.
enum FindKeys {
    /// `command` is the editing command AppKit made of the key, such as `insertNewline:`. Nil
    /// leaves the key to the field.
    static func action(forCommand command: String, isShiftDown: Bool) -> FindKeyAction? {
        switch command {
        // Return, with any modifier: a find field has no second line. A search starts on the newest
        // hit, so Return walks back through the conversation like a terminal's find bar. Going forward
        // from the last hit would start over at the top, as far from the reader as a hit can be.
        // The chevrons and Command-G still mean further down.
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:":
            isShiftDown ? .next : .previous
        case "cancelOperation:":
            .close
        default:
            nil
        }
    }

    /// "3 of 17", "Not Found", or nothing while there is nothing to say.
    ///
    /// While a search is under way the last count stays up, since one that blinks out on every
    /// keystroke is worse than one a moment old. Only "Not Found" waits for the answer, because
    /// saying it early would be wrong.
    static func status(query: String, currentIndex: Int?, count: Int, isUpToDate: Bool) -> String? {
        guard ChatFindSearch.isSearchable(query) else { return nil }
        guard count > 0 else { return isUpToDate ? "Not Found" : nil }
        guard let currentIndex else { return "\(count)" }
        return "\(currentIndex + 1) of \(count)"
    }

    /// What VoiceOver is told when a search is answered or moves to another hit. The cursor stays in
    /// the field, so the count beside it would never be read.
    ///
    /// Nil while there is nothing to say: no searchable string, or an answer still on its way. Hits
    /// that come in while a reply streams change the count but are not announced one by one.
    struct Announcement: Equatable {
        var query: String
        var currentIndex: Int?
        var isEmpty: Bool

        init?(query: String, currentIndex: Int?, count: Int, isUpToDate: Bool) {
            guard isUpToDate, ChatFindSearch.isSearchable(query) else { return nil }
            self.query = query
            self.currentIndex = currentIndex
            isEmpty = count == 0
        }
    }

    /// The same for VoiceOver, which should not have to make sense of "3 of 17" on its own.
    static func spokenStatus(query: String, currentIndex: Int?, count: Int, isUpToDate: Bool) -> String? {
        guard ChatFindSearch.isSearchable(query) else { return nil }
        guard count > 0 else { return isUpToDate ? "No matches" : nil }
        guard let currentIndex else { return count == 1 ? "1 match" : "\(count) matches" }
        return "Match \(currentIndex + 1) of \(count)"
    }
}

/// Find in the conversation: one small glass bar over the transcript's top trailing corner, as
/// the system's own find bars sit over what they search.
struct ChatFindBar: View {
    let find: ChatFindModel
    /// Closes the bar and gives the keyboard back to the composer.
    let close: @MainActor () -> Void

    var body: some View {
        @Bindable var find = find
        let hasMatches = !find.matches.isEmpty
        let status = FindKeys.status(query: find.query, currentIndex: find.currentIndex, count: find.matches.count, isUpToDate: find.isUpToDate)
        let announcement = FindKeys.Announcement(
            query: find.query, currentIndex: find.currentIndex, count: find.matches.count, isUpToDate: find.isUpToDate
        )

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            FindTextField(text: $find.query, find: find, focusRequests: find.focusRequests) { action in
                switch action {
                case .next: find.step(forward: true)
                case .previous: find.step(forward: false)
                case .close: close()
                }
            }
            .frame(minWidth: 60, maxWidth: 170)
            // Always there, so the field keeps its place when the first hits come in.
            Text(verbatim: status ?? "")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .trailing)
                .accessibilityLabel(
                    FindKeys.spokenStatus(query: find.query, currentIndex: find.currentIndex, count: find.matches.count, isUpToDate: find.isUpToDate) ?? ""
                )
                .accessibilityHidden(status == nil)
                .accessibilityIdentifier("chat.find.count")
            HStack(spacing: 0) {
                stepButton("Previous Match", symbol: "chevron.up", shortcut: "\u{21E7}\u{2318}G", identifier: "chat.find.previous") {
                    find.step(forward: false)
                }
                stepButton("Next Match", symbol: "chevron.down", shortcut: "\u{2318}G", identifier: "chat.find.next") {
                    find.step(forward: true)
                }
            }
            .disabled(!hasMatches)
            Button("Done", action: close)
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .help("Close Find (Esc)")
                .accessibilityIdentifier("chat.find.done")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .glassEffect(.regular, in: .rect(cornerRadius: ChatMetrics.surfaceRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find")
        .accessibilityIdentifier("chat.find")
        .onChange(of: announcement) {
            guard announcement != nil,
                  let spoken = FindKeys.spokenStatus(query: find.query, currentIndex: find.currentIndex, count: find.matches.count, isUpToDate: true)
            else { return }
            ChatAnnouncement.post(spoken)
        }
    }

    static let height: CGFloat = 36

    private func stepButton(_ title: String, symbol: String, shortcut: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        // Neutral like Done and like the system's own find bars; the borderless style would
        // draw them in the accent color, also while they are disabled.
        .foregroundStyle(.secondary)
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The find field. An AppKit field rather than a SwiftUI one, because the bar needs Return,
/// Shift-Return and Esc as the field editor reports them, after an input method had its turn.
private struct FindTextField: NSViewRepresentable {
    @Binding var text: String
    let find: ChatFindModel
    /// Read by the bar so a new request updates this view; the model keeps count of which were
    /// answered.
    let focusRequests: Int
    let perform: (FindKeyAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "Find"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Find in Conversation")
        field.setAccessibilityIdentifier("chat.find.field")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard find.takeFocusRequest() else { return }
        // A step later: a field that was only just made is not in its window yet, and a command
        // palette that sent the request is still handing the keyboard back.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            // Selects what the field holds, so typing replaces the last search.
            window.makeFirstResponder(field)
        }
    }

    /// As wide as it is offered, so the bar decides, not the text typed so far.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let height = nsView.intrinsicContentSize.height
        guard let width = proposal.width, width.isFinite else { return CGSize(width: 170, height: height) }
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindTextField

        init(_ parent: FindTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let isShiftDown = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            guard let action = FindKeys.action(forCommand: NSStringFromSelector(selector), isShiftDown: isShiftDown) else { return false }
            parent.perform(action)
            return true
        }
    }
}

#if DEBUG
#Preview("Find Bar") {
    let find = ChatFindModel()
    find.present()
    find.query = "password"
    return VStack(alignment: .trailing, spacing: 16) {
        ChatFindBar(find: find, close: {})
        ChatFindBar(find: ChatFindModel(), close: {})
    }
    .padding(30)
    .frame(width: 480, alignment: .trailing)
    .background(Color(nsColor: .textBackgroundColor))
}
#endif
