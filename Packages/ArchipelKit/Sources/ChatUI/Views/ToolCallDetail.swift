import ACPKit
import EditorUI
import SwiftUI
import UISupport

/// What a tool call row shows when opened: the files it touched, its output and its diffs.
struct ToolCallDetail: View {
    let call: ToolCall
    let openFile: (URL, Int?) -> Void

    @Environment(\.chatWorkingDirectory) private var workingDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !call.locations.isEmpty {
                locations
            }
            if call.commandDiffersFromTitle, let command = call.command {
                OutputBlock(text: command)
            }
            ForEach(Array(call.textContent.enumerated()), id: \.offset) { _, text in
                OutputBlock(text: text)
            }
            if let output = call.terminalOutput, !output.isEmpty {
                OutputBlock(text: output)
            }
            if let code = call.terminalExitCode, code != 0 {
                Label("Exit code \(code)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(call.diffs) { diff in
                InlineDiffView(oldText: diff.oldText, newText: diff.newText)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var locations: some View {
        let (shown, more) = call.listedLocations
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, location in
                Button {
                    openFile(location.url, location.line)
                } label: {
                    Label {
                        SearchableText(text: location.displayLabel(relativeTo: workingDirectory))
                    } icon: {
                        Image(systemName: FileSymbol.name(for: location.url.lastPathComponent))
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help(location.path)
                .accessibilityHint("Opens the file")
            }
            if more > 0 {
                Text("and \(more) more")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }
}

/// Monospaced text that scrolls both ways inside a capped height: command output, search hits.
struct OutputBlock: View {
    let text: String
    var maximumHeight: CGFloat = 200

    private static let padding: CGFloat = 10

    @Environment(\.textHighlight) private var highlight
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        let tail = OutputTail.tail(of: text)
        let rows = tail.lineCount + (tail.hiddenLines > 0 ? 1 : 0)
        // Lines never wrap, so the height is known without measuring. A scroll view would
        // otherwise take the whole cap even for two lines.
        let height = CGFloat(max(rows, 1)) * ChatMetrics.codeLineHeight + Self.padding * 2
        let shownHeight = min(height, maximumHeight)
        // The line Find is on, when it is in this block. The block shows a dozen lines of up to
        // four hundred, so the hit is brought into it like the transcript brings its row.
        let currentRow = highlight?.currentLine(in: tail.text).map { $0 + (tail.hiddenLines > 0 ? 1 : 0) }

        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if tail.hiddenLines > 0 {
                    Text("\(tail.hiddenLines) earlier lines not shown")
                        .foregroundStyle(.tertiary)
                        .frame(height: ChatMetrics.codeLineHeight)
                }
                SearchableText(text: tail.text)
                    .lineSpacing(ChatMetrics.codeLineHeight - Self.naturalLineHeight)
                    .fixedSize()
                    .textSelection(.enabled)
            }
            .font(ChatMetrics.codeFont)
            .foregroundStyle(.secondary)
            .padding(Self.padding)
        }
        .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
        // The end of the output is the result, so a long one opens there.
        .defaultScrollAnchor(.bottomLeading)
        .scrollPosition($position)
        // Also when the block first shows: Find opens the row with the hit already current.
        .onChange(of: currentRow, initial: true) {
            guard let currentRow else { return }
            position.scrollTo(y: CodeBlockScroll.offset(centering: currentRow, padding: Self.padding, blockHeight: shownHeight))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: shownHeight)
        .background(.quinary, in: .rect(cornerRadius: ChatMetrics.blockRadius, style: .continuous))
    }

    /// What AppKit lays a 12pt monospaced system line out at; the rest of the line height is
    /// added as spacing so the block is as tall as computed.
    private static let naturalLineHeight: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: ChatMetrics.codeFontSize, weight: .regular)
        return NSLayoutManager().defaultLineHeight(for: font)
    }()
}

/// Where a block of fixed-height code lines scrolls to for Find.
enum CodeBlockScroll {
    /// The offset that puts line `row`, counted from zero, in the middle of a block
    /// `blockHeight` tall whose lines start `padding` below its top. Lines never wrap and are
    /// `ChatMetrics.codeLineHeight` tall, so nothing has to be measured.
    static func offset(centering row: Int, padding: CGFloat, blockHeight: CGFloat) -> CGFloat {
        max(0, padding + CGFloat(row) * ChatMetrics.codeLineHeight - (blockHeight - ChatMetrics.codeLineHeight) / 2)
    }
}

extension TextHighlight {
    /// The line of `text` the current hit is in, counted from zero. Nil unless `text` is the
    /// piece the search is on.
    func currentLine(in text: String) -> Int? {
        guard let current, current.text == text else { return nil }
        let ranges = Self.ranges(of: query, in: text)
        guard ranges.indices.contains(current.occurrence) else { return nil }
        let newline = UInt8(ascii: "\n")
        return text[..<ranges[current.occurrence].lowerBound].utf8.count { $0 == newline }
    }
}
