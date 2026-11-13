import ArchipelCore
import SwiftUI

/// The floating "Go to…" / "Open Quickly…" panel. Attach it as an overlay on the window content.
struct CommandPalette: View {
    @Environment(CommandPaletteModel.self) private var palette

    var body: some View {
        if palette.isPresented {
            ZStack(alignment: .top) {
                // Swallows clicks so they never reach the terminal underneath.
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { palette.dismiss() }
                    .ignoresSafeArea()
                PalettePanel()
                    .frame(width: 560)
                    .padding(.top, 80)
            }
        }
    }
}

private struct PalettePanel: View {
    @Environment(CommandPaletteModel.self) private var palette

    private let rowHeight: CGFloat = 34
    private let maxVisibleRows = 10

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                PaletteField(
                    placeholder: palette.mode == .goTo ? "Go to…" : "Open file…",
                    text: palette.query,
                    onChange: { palette.setQuery($0) },
                    onMove: { palette.move($0) },
                    onSubmit: { palette.activateSelection() },
                    onCancel: { palette.dismiss() }
                )
                .frame(height: 24)
                if palette.isLoadingFiles {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            results
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        // A tap on the panel itself must not reach the dismissing backdrop.
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {}
    }

    @ViewBuilder
    private var results: some View {
        if palette.rows.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 56)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(palette.rows.enumerated()), id: \.element.id) { index, row in
                            PaletteRowView(row: row, isSelected: index == palette.selection)
                                .frame(height: rowHeight)
                                .contentShape(Rectangle())
                                .onTapGesture { palette.activate(index) }
                                .onContinuousHover { phase in
                                    if case .active = phase, palette.selection != index { palette.selection = index }
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(palette.rows.count), CGFloat(maxVisibleRows)) * rowHeight + 12)
                .onChange(of: palette.selection) { _, selection in
                    guard palette.rows.indices.contains(selection) else { return }
                    proxy.scrollTo(palette.rows[selection].id)
                }
                .onChange(of: palette.rows.first?.id) {
                    if let first = palette.rows.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    private var emptyMessage: String {
        if palette.isLoadingFiles { return "Loading files…" }
        if palette.mode == .openFile, palette.query.isEmpty { return "No files in this worktree" }
        return "No results"
    }
}

private struct PaletteRowView: View {
    let row: PaletteRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? .primary : .secondary)
            highlighted(row.title, row.titleMatches)
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = row.subtitle {
                highlighted(subtitle, row.subtitleMatches)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let activity = row.activity {
                StatusGlyph(activity: activity)
            }
            if let hint = row.shortcutHint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.tint.opacity(0.22))
            }
        }
    }

    /// Matched characters are bold and tinted. Runs are built per stretch, not per character, to keep long lists cheap.
    private func highlighted(_ string: String, _ matches: Set<Int>) -> Text {
        guard !matches.isEmpty else { return Text(string) }
        var result = AttributedString()
        var run = ""
        var runMatches = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if runMatches {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .accentColor
            }
            result += piece
            run = ""
        }
        for (index, character) in string.enumerated() {
            let isMatch = matches.contains(index)
            if isMatch != runMatches { flush() }
            runMatches = isMatch
            run.append(character)
        }
        flush()
        return Text(result)
    }
}

// MARK: Text field

/// An AppKit text field rather than SwiftUI's, because the terminal underneath is an AppKit view that holds first
/// responder and SwiftUI's focus state does not reliably take it away.
private struct PaletteField: NSViewRepresentable {
    let placeholder: String
    let text: String
    let onChange: (String) -> Void
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        let isComposing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if field.stringValue != text, !isComposing { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField

        init(_ parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        // Ctrl-P and Ctrl-N reach here as moveUp: and moveDown: through AppKit's default key bindings.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        claimFocus(attempts: 4)
    }

    /// Retries because the first attempt can race the terminal's own focus handling and SwiftUI's layout pass.
    private func claimFocus(attempts: Int) {
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            if self.currentEditor() == nil { window.makeFirstResponder(self) }
            guard attempts > 1 else { return }
            try? await Task.sleep(for: .milliseconds(40))
            if self.window != nil, self.currentEditor() == nil { self.claimFocus(attempts: attempts - 1) }
        }
    }
}
