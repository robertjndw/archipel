import SwiftUI
import TerminalKit

/// Floats in the terminal's top trailing corner while Ghostty's scrollback search is open.
/// Return and Shift-Return step through the matches, Escape closes it and hands the keyboard back
/// to the terminal.
struct TerminalSearchBar: View {
    @Bindable var search: TerminalSearch

    var body: some View {
        if search.isActive {
            TerminalSearchField(
                needle: $search.needle,
                total: search.total,
                selected: search.selected,
                focusRequests: search.focusRequests,
                takeFocusRequest: search.takeFocusRequest,
                next: search.next,
                previous: search.previous,
                close: search.close
            )
        }
    }
}

private struct TerminalSearchField: View {
    @Binding var needle: String
    let total: Int?
    let selected: Int?
    let focusRequests: Int
    /// Whether the search was asked for since a field last took the keyboard for it.
    let takeFocusRequest: () -> Bool
    let next: () -> Void
    let previous: () -> Void
    let close: () -> Void
    @FocusState private var isFocused: Bool

    private var count: String? {
        guard !needle.isEmpty, let total else { return nil }
        if total == 0 { return "No matches" }
        guard let selected else { return total == 1 ? "1 match" : "\(total) matches" }
        return "\(selected + 1) of \(total)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find", text: $needle)
                .textFieldStyle(.plain)
                .frame(width: 150)
                .focused($isFocused)
                .accessibilityIdentifier("terminal.search.field")
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { previous() } else { next() }
                    return .handled
                }
                // Escape reaches a text field as cancelOperation:, not as a key press.
                .onExitCommand(perform: close)
            if let count {
                Text(count)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Group {
                Button("Previous Match", systemImage: "chevron.up", action: previous)
                    .accessibilityIdentifier("terminal.search.previous")
                Button("Next Match", systemImage: "chevron.down", action: next)
                    .accessibilityIdentifier("terminal.search.next")
                Button("Close Find", systemImage: "xmark", action: close)
                    .accessibilityIdentifier("terminal.search.close")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: Chrome.controlHeight)
        .glassEffect(.regular, in: .capsule)
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.search")
        // Not on every appearance: the bar comes back with its terminal for as long as the search
        // is open, and the keyboard belongs to the pane the user is in then.
        .onAppear { if takeFocusRequest() { isFocused = true } }
        .onChange(of: focusRequests) { if takeFocusRequest() { isFocused = true } }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var empty = ""
    @Previewable @State var typed = "error"
    VStack(alignment: .trailing, spacing: 0) {
        TerminalSearchField(needle: $empty, total: nil, selected: nil, focusRequests: 0, takeFocusRequest: { false }, next: {}, previous: {}, close: {})
        TerminalSearchField(needle: $typed, total: 12, selected: 2, focusRequests: 0, takeFocusRequest: { false }, next: {}, previous: {}, close: {})
        TerminalSearchField(needle: $typed, total: 0, selected: nil, focusRequests: 0, takeFocusRequest: { false }, next: {}, previous: {}, close: {})
            .environment(\.colorScheme, .dark)
    }
    .frame(width: 420, alignment: .trailing)
    .padding()
    .background(Color.black.opacity(0.85))
}
#endif
