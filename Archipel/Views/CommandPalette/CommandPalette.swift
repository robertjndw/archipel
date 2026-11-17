import ArchipelCore
import SwiftUI

/// The floating "Go to…" / "Open Quickly…" panel. Attach it as an overlay on the window content.
struct CommandPalette: View {
    @Environment(CommandPaletteModel.self) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if palette.isPresented {
                // Swallows clicks so they never reach the terminal underneath.
                // Clear, like Spotlight: the panel's glass carries the focus.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { palette.dismiss() }
                    .ignoresSafeArea()
                PalettePanel()
                    .frame(width: 600)
                    .padding(.top, 80)
                    .transition(transition)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .bouncy(duration: 0.3, extraBounce: 0.05), value: palette.isPresented)
    }

    private var transition: AnyTransition {
        .asymmetric(
            insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity
        )
    }
}

private struct PalettePanel: View {
    @Environment(CommandPaletteModel.self) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rowHeight: CGFloat = 36
    private let maxVisibleRows = 10
    /// Rows are inset by this much from the panel edge; their radius follows.
    private let rowInset: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                PaletteField(
                    placeholder: palette.mode == .goTo ? "Go to…" : "Open file…",
                    text: palette.query,
                    onChange: { palette.setQuery($0) },
                    onMove: { palette.move($0) },
                    onSubmit: { palette.activateSelection() },
                    onCancel: { palette.dismiss() }
                )
                .frame(height: 28)
                if palette.isLoadingFiles {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
                .padding(.horizontal, rowInset)
            results
            footer
        }
        .animation(reduceMotion ? nil : Motion.disclosure, value: palette.rows.count)
        // Over a busy terminal, clear glass lets the text behind compete with the rows. A tinted
        // backing fixes that, in light and dark mode.
        .background(.background.opacity(0.5), in: .rect(cornerRadius: Chrome.panelRadius))
        .glassEffect(.regular, in: .rect(cornerRadius: Chrome.panelRadius))
        // A tap on the panel itself must not reach the dismissing backdrop.
        .contentShape(.rect(cornerRadius: Chrome.panelRadius))
        .onTapGesture {}
    }

    /// Only keys that are not obvious from the field itself.
    private var footer: some View {
        Text("↩ to open  ·  ↑ ↓ or ⌃N ⌃P to move  ·  > for commands only")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, rowInset)
            .padding(.bottom, 8)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var results: some View {
        if palette.rows.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(palette.rows.enumerated()), id: \.element.id) { index, row in
                            PaletteRowView(row: row, isSelected: index == palette.selection, cornerRadius: Chrome.panelRadius - rowInset)
                                .frame(height: rowHeight)
                                .contentShape(.rect)
                                .onTapGesture { palette.activate(index) }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)
                                .accessibilityAddTraits(index == palette.selection ? [.isButton, .isSelected] : .isButton)
                                .accessibilityIdentifier("palette.row")
                                .onContinuousHover { phase in
                                    if case .active = phase, palette.selection != index { palette.selection = index }
                                }
                        }
                    }
                    .padding(rowInset)
                }
                .frame(height: min(CGFloat(palette.rows.count), CGFloat(maxVisibleRows)) * rowHeight + rowInset * 2)
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
    let cornerRadius: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Image(symbol: row.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Text.highlighting(row.title, matches: row.titleMatches)
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = row.subtitle {
                Text.highlighting(subtitle, matches: row.subtitleMatches)
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
                ShortcutHint(hint)
            }
        }
        .padding(.horizontal, 10)
        // Without this the highlight only covers the text, not the whole row.
        .frame(maxHeight: .infinity)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.tint.opacity(0.22))
            }
        }
    }
}

/// Menu-style key glyphs: each key in its own fixed-width cell, so hints line
/// up down the list the way they do in a menu.
private struct ShortcutHint: View {
    let keys: [String]

    init(_ hint: String) {
        keys = hint.map(String.init)
    }

    var body: some View {
        HStack(spacing: 1) {
            // A shortcut never repeats a key, so the key itself is a stable identity.
            ForEach(keys, id: \.self) { key in
                Text(verbatim: key)
                    .frame(minWidth: 13)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: keys.joined()))
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
        field.font = .systemFont(ofSize: 20)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("palette.query")
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

#if DEBUG
private func previewPalette(_ query: String) -> some View {
    let model = AppModel.preview()
    let palette = CommandPaletteModel()
    let actions = AppActions(
        model: model,
        palette: palette,
        switcher: TabSwitcherModel(),
        updater: Updater(),
        isAddingProject: .constant(false),
        openSettings: {}
    )
    let commands = PaletteCommand.standard(model: model, actions: actions)
    palette.present(.goTo, app: model, commands: commands)
    palette.setQuery(query)
    return CommandPalette()
        .environment(palette)
        .frame(width: 900, height: 600, alignment: .top)
        .background(.windowBackground)
}

#Preview("Empty Query") {
    previewPalette("")
}

#Preview("Results") {
    previewPalette("off")
}

#Preview("Results, Dark") {
    previewPalette("rev")
        .preferredColorScheme(.dark)
}

#Preview("Commands Only") {
    previewPalette(">split")
}

#Preview("No Results") {
    previewPalette("qwxz")
}
#endif
