import AppKit
import Synchronization
import SwiftUI
import UISupport

/// Markdown as native text, for chat messages. Built to be fed a reply that is still streaming in:
/// only the end of the text is parsed again as it grows, and only the last block is redrawn.
///
/// Links go through the environment's `openURL`, so the host decides what a click does.
public struct MarkdownText: View {
    private let source: String
    @State private var parser = StreamParserBox()
    @Environment(\.markdownPathLinker) private var paths

    public init(_ source: String) {
        self.source = source
    }

    public var body: some View {
        MarkdownBlockStack(blocks: parser.blocks(for: source, paths: paths), spacing: MarkdownMetrics.blockSpacing)
            .font(.body)
            .textSelection(.enabled)
    }
}

/// Holds the parser outside SwiftUI's state tracking: updating it inside `body` must not count as
/// a state change, or every new chunk would render twice.
@MainActor
private final class StreamParserBox {
    private var parser = MarkdownStreamParser()

    func blocks(for source: String, paths: MarkdownPathLinker?) -> [MarkdownBlock] {
        // Links found against another folder would be wrong, so a new linker starts over.
        if parser.paths !== paths { parser = MarkdownStreamParser(paths: paths) }
        return parser.update(source)
    }
}

enum MarkdownMetrics {
    static let blockSpacing: CGFloat = 12
    static let lineSpacing: CGFloat = 3
    static let listItemSpacing: CGFloat = 6
    static let markerSpacing: CGFloat = 6
    static let codeFontSize: CGFloat = 12
    static let codePadding: CGFloat = 12
    static let cornerRadius = CornerRadius.control
}

struct MarkdownBlockStack: View {
    let blocks: [MarkdownBlock]
    let spacing: CGFloat
    /// The place of the first block's text among the document's pieces; see `TextHighlight`.
    var firstPiece = 0

    var body: some View {
        // Blocks only ever grow at the end, so every earlier block keeps its number while the
        // last one streams in.
        let pieces = blocks.reduce(into: [firstPiece]) { starts, block in starts.append(starts[starts.count - 1] + block.pieceCount) }
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks.indices, id: \.self) { index in
                let block = blocks[index]
                MarkdownBlockView(block: block, firstPiece: pieces[index])
                    .equatable()
                    // A heading belongs to what follows it, so it sits a little further from
                    // what came before.
                    .padding(.top, block.isHeading && block.id > 0 ? 6 : 0)
            }
        }
    }
}

private extension MarkdownBlock {
    var isHeading: Bool {
        if case .heading = kind { true } else { false }
    }
}

/// Equatable on the block and its place, so while the last block grows SwiftUI skips all the
/// others.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    var firstPiece = 0

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            HighlightedText(text, piece: firstPiece)
                .lineSpacing(MarkdownMetrics.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            HighlightedText(text, piece: firstPiece)
                .font(Self.font(forHeading: level))
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(let language, let code):
            MarkdownCodeBlock(language: language, code: code, piece: firstPiece)
        case .blockQuote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 3)
                MarkdownBlockStack(blocks: blocks, spacing: MarkdownMetrics.blockSpacing, firstPiece: firstPiece)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            MarkdownList(items: items, start: nil, firstPiece: firstPiece)
        case .orderedList(let start, let items):
            MarkdownList(items: items, start: start, firstPiece: firstPiece)
        case .table(let table):
            MarkdownTableView(table: table, firstPiece: firstPiece)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        }
    }

    // Chat replies should not shout, so even a top-level heading stays close to the body size.
    private static func font(forHeading level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

// MARK: Lists

extension EnvironmentValues {
    @Entry var markdownListDepth = 0
}

struct MarkdownList: View {
    let items: [MarkdownListItem]
    /// Nil for an unordered list.
    let start: Int?
    var firstPiece = 0
    @Environment(\.markdownListDepth) private var depth

    var body: some View {
        let pieces = items.reduce(into: [firstPiece]) { starts, item in
            starts.append(starts[starts.count - 1] + MarkdownBlock.pieceCount(of: item.blocks))
        }
        VStack(alignment: .leading, spacing: MarkdownMetrics.listItemSpacing) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(alignment: .firstTextBaseline, spacing: MarkdownMetrics.markerSpacing) {
                    marker(for: item)
                    MarkdownBlockStack(blocks: item.blocks, spacing: MarkdownMetrics.listItemSpacing + 2, firstPiece: pieces[index])
                }
            }
        }
        .environment(\.markdownListDepth, depth + 1)
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem) -> some View {
        // The widest marker of the list sits invisibly under every marker, so the column is as
        // wide as the list needs and the numbers line up on their right edge.
        ZStack(alignment: start == nil ? .center : .trailing) {
            Text(widestMarker).hidden()
            if let checkbox = item.checkbox {
                Text(Image(systemName: checkbox == .checked ? "checkmark.square" : "square"))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(checkbox == .checked ? Text("Completed") : Text("Not completed"))
            } else if let start {
                Text(verbatim: "\(start + item.id).")
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: bullet)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .accessibilityHidden(item.checkbox == nil)
    }

    private var widestMarker: String {
        if let start {
            // With monospaced digits the longest number is the widest.
            return "\(start + max(items.count - 1, 0))."
        }
        return items.contains { $0.checkbox != nil } ? "\u{25A1}" : "0"
    }

    private var bullet: String {
        switch depth {
        case 0: "\u{2022}"
        case 1: "\u{25E6}"
        default: "\u{25AA}"
        }
    }
}

// MARK: Tables

struct MarkdownTableView: View {
    let table: MarkdownTable
    /// The place of the first header cell; the cells follow row by row, as they are searched.
    var firstPiece = 0

    /// Past this a cell wraps instead of pushing the table ever wider.
    private static let maximumCellWidth: CGFloat = 320

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, column: column, piece: firstPiece + column)
                            .fontWeight(.semibold)
                            .gridColumnAlignment(horizontalAlignment(column))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    // Every row has as many cells as the table has columns.
                    let rowStart = firstPiece + table.header.count + index * table.alignments.count
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            self.cell(cell, column: column, piece: rowStart + column)
                        }
                    }
                }
            }
            // The scroll view's content is laid out without a width limit.
            .fixedSize()
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func cell(_ text: AttributedString, column: Int, piece: Int) -> some View {
        CappedWidthLayout(maximumWidth: Self.maximumCellWidth) {
            HighlightedText(text, piece: piece)
                .multilineTextAlignment(textAlignment(column))
        }
        .padding(.vertical, 5)
            .padding(.leading, column == 0 ? 0 : 10)
            .padding(.trailing, column == table.alignments.count - 1 ? 0 : 10)
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .center: .center
        case .trailing: .trailing
        case .leading, nil: .leading
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .center: .center
        case .trailing: .trailing
        case .leading, nil: .leading
        }
    }
}

/// Its one subview at its ideal width up to a maximum, and as tall as it needs at that width.
///
/// Inside a horizontal scroll view nothing limits the width, and `frame(maxWidth:)` would cap the
/// width while the height is still measured for a single line, so a long cell spilled out of its row.
private struct CappedWidthLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = min(subview.sizeThatFits(.unspecified).width, maximumWidth)
        let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: Code

struct MarkdownCodeBlock: View {
    let code: String
    /// Nil for a block without a language, which has no header row.
    let language: String?
    /// The code's place among the pieces of its Markdown document.
    let piece: Int?

    init(language: String?, code: String, piece: Int? = nil) {
        self.language = language.flatMap { $0.isEmpty ? nil : $0 }
        self.code = code
        self.piece = piece
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted: HighlightedCode?
    @State private var isHovering = false
    @State private var copied = false
    @FocusState private var isCopyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                HStack {
                    Text(verbatim: language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Nothing to cover up here, so no need to hide it until hover.
                    copyButton(alwaysVisible: true)
                }
                .padding(.leading, MarkdownMetrics.codePadding)
                .padding(.trailing, 6)
                .padding(.top, 4)
            }
            ScrollView(.horizontal) {
                HighlightedText(displayed, piece: piece)
                    .font(.system(size: MarkdownMetrics.codeFontSize, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(.horizontal, MarkdownMetrics.codePadding)
                    .padding(.top, language == nil ? MarkdownMetrics.codePadding : 2)
                    .padding(.bottom, MarkdownMetrics.codePadding)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if language == nil {
                // The backing keeps the button legible when it lands on a long first line. Glass, as
                // every floating control in the app is; the app uses no materials.
                copyButton(alwaysVisible: false)
                    .glassEffect(.regular, in: .capsule)
                    .padding(6)
            }
        }
        .background(.quinary, in: .rect(cornerRadius: MarkdownMetrics.cornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .task(id: HighlightCache.Key(code: code, language: language)) {
            await highlight()
        }
    }

    /// Without a header the button sits on top of the code, so it hides until hover. It also
    /// shows on keyboard focus, otherwise tabbing lands on an invisible button.
    private func copyButton(alwaysVisible: Bool) -> some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy Code")
        .focused($isCopyFocused)
        .opacity(alwaysVisible || isHovering || isCopyFocused || copied ? 1 : 0)
        .animation(reduceMotion ? nil : Motion.hover, value: isHovering || isCopyFocused)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
    }

    /// While a block streams in, the colours of the part that was already highlighted stay on
    /// and only the new text is plain, so the block does not flash between coloured and plain.
    private var displayed: AttributedString {
        guard let highlighted else { return AttributedString(code) }
        if highlighted.code == code { return highlighted.text }
        guard code.utf8.starts(with: highlighted.code.utf8),
              let split = highlighted.code.endIndex.samePosition(in: code) else { return AttributedString(code) }
        return highlighted.text + AttributedString(code[split...])
    }

    private func highlight() async {
        guard let language, !code.isEmpty else { return }
        let key = HighlightCache.Key(code: code, language: language)
        if let cached = HighlightCache.shared[key] {
            highlighted = cached
            return
        }
        // The code changed while on screen, so it is most likely still streaming. Highlighting
        // waits until it pauses; cancellation by the next change is the debounce.
        if highlighted != nil {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        guard let runs = await SyntaxHighlighter.shared.runs(for: code, grammar: language), !Task.isCancelled else { return }
        let result = HighlightedCode(code: code, text: await Self.colored(code, runs: runs, palette: SyntaxPalette.colors))
        guard !Task.isCancelled else { return }
        HighlightCache.shared[key] = result
        highlighted = result
    }

    @concurrent
    private nonisolated static func colored(_ code: String, runs: [HighlightRun], palette: [Color]) async -> AttributedString {
        var result = AttributedString()
        let utf16 = code.utf16
        var position = utf16.startIndex
        var offset = 0
        for run in runs.sorted(by: { $0.location < $1.location }) where run.location >= offset {
            guard let start = utf16.index(position, offsetBy: run.location - offset, limitedBy: utf16.endIndex),
                  let end = utf16.index(start, offsetBy: run.length, limitedBy: utf16.endIndex) else { break }
            if position < start { result += AttributedString(code[position..<start]) }
            var piece = AttributedString(code[start..<end])
            piece.swiftUI.foregroundColor = palette[Int(run.scope.rawValue)]
            result += piece
            position = end
            offset = run.location + run.length
        }
        if position < utf16.endIndex { result += AttributedString(code[position...]) }
        return result
    }
}

struct HighlightedCode: Sendable {
    var code: String
    var text: AttributedString
}

/// The editor's syntax colours. They are dynamic AppKit colours, so they follow light and dark
/// without highlighting again.
@MainActor
private enum SyntaxPalette {
    static let colors: [Color] = (0...SyntaxScope.deletion.rawValue).map { raw in
        SyntaxScope(rawValue: raw).map { Color(nsColor: EditorTheme.color(for: $0)) } ?? .primary
    }
}

/// Highlighted code by its text and language. Message views come and go as a transcript scrolls,
/// and a block that scrolls back in should not be highlighted a second time.
final class HighlightCache: Sendable {
    struct Key: Hashable, Sendable {
        var code: String
        var language: String?
    }

    static let shared = HighlightCache()

    private static let capacity = 200
    private let entries = Mutex<[Key: HighlightedCode]>([:])

    subscript(key: Key) -> HighlightedCode? {
        get { entries.withLock { $0[key] } }
        set {
            entries.withLock { entries in
                // Crude, but a transcript rarely has this many distinct blocks on hand, and
                // starting over only costs highlighting again.
                if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
                entries[key] = newValue
            }
        }
    }
}

// MARK: Previews

#if DEBUG
enum MarkdownSamples {
    static let kitchenSink = #"""
    # Refactoring the session store

    I moved the persistence into `SessionStore` and kept the public API **unchanged**. A few
    *details* are worth a look, and the old ~~`legacyLoad()`~~ path is gone. See the
    [migration notes](https://example.com/notes) or `docs/sessions.md`.

    ## What changed

    1. Sessions are written atomically, through a temporary file.
    2. Loading tolerates a missing file:
       - an empty store is returned
       - a warning is logged once
         - nested a third level
    3. The cache is keyed by worktree path.

    Next, in a follow-up:

    9. Drop the old file format.
    10. Remove the migration flag.
    11. Delete `LegacySessionStore`.

    ### Checklist

    - [x] Unit tests for the store
    - [x] Migration from the old format
    - [ ] UI tests for the restore flow

    | Case | Before | After |
    |:-----|:------:|------:|
    | Cold launch | 420 ms | 180 ms |
    | Warm launch | 95 ms | 60 ms |
    | Restore 50 sessions | 2.1 s | 0.4 s |

    > Note: the store now refuses to load a file written by a newer version, instead of
    > silently dropping fields it does not know.

    ```swift
    struct SessionStore: Sendable {
        let url: URL

        func save(_ sessions: [Session]) throws {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: url, options: .atomic) // never half-written
        }
    }
    ```

    Run the tests with:

    ```sh
    swift test --filter SessionStoreTests --parallel
    ```

    ---

    That's all. Ask if anything is unclear.
    """#
}

private struct StreamingPreview: View {
    @State private var length = 0
    private let text = MarkdownSamples.kitchenSink

    var body: some View {
        ScrollView {
            MarkdownText(String(text.prefix(length)))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            while length < text.count {
                try? await Task.sleep(for: .milliseconds(30))
                length = min(text.count, length + Int.random(in: 1...8))
            }
        }
    }
}

#Preview("Kitchen Sink") {
    ScrollView {
        MarkdownText(MarkdownSamples.kitchenSink)
            .padding(20)
    }
    .frame(width: 680, height: 900)
}

#Preview("Kitchen Sink, Dark") {
    ScrollView {
        MarkdownText(MarkdownSamples.kitchenSink)
            .padding(20)
    }
    .frame(width: 680, height: 900)
    .preferredColorScheme(.dark)
}

#Preview("Streaming") {
    StreamingPreview()
        .frame(width: 680, height: 900)
}
#endif
