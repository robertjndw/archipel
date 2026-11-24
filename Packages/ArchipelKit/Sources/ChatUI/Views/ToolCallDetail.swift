import ACPKit
import SwiftUI
import UISupport

/// What a tool call row shows when opened: the files it touched, its output and its diffs.
struct ToolCallDetail: View {
    let call: ToolCall
    let openFile: (URL, Int?) -> Void

    @Environment(\.chatWorkingDirectory) private var workingDirectory

    /// A search can list hundreds of hits; the first few say where it looked.
    private static let maximumLocations = 6

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
        let unique = call.locations.reduce(into: [ToolCallLocation]()) { result, location in
            if !result.contains(location) { result.append(location) }
        }
        let shown = unique.prefix(Self.maximumLocations)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, location in
                Button {
                    openFile(location.url, location.line)
                } label: {
                    Label(location.displayLabel(relativeTo: workingDirectory), systemImage: FileSymbol.name(for: location.url.lastPathComponent))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help(location.path)
                .accessibilityHint("Opens the file")
            }
            if unique.count > shown.count {
                Text("and \(unique.count - shown.count) more")
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

    var body: some View {
        let tail = OutputTail.tail(of: text)
        let rows = tail.lineCount + (tail.hiddenLines > 0 ? 1 : 0)
        // Lines never wrap, so the height is known without measuring. A scroll view would
        // otherwise take the whole cap even for two lines.
        let height = CGFloat(max(rows, 1)) * ChatMetrics.codeLineHeight + Self.padding * 2

        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if tail.hiddenLines > 0 {
                    Text("\(tail.hiddenLines) earlier lines not shown")
                        .foregroundStyle(.tertiary)
                        .frame(height: ChatMetrics.codeLineHeight)
                }
                Text(verbatim: tail.text)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: min(height, maximumHeight))
        .background(.quinary, in: .rect(cornerRadius: ChatMetrics.blockRadius, style: .continuous))
    }

    /// What AppKit lays a 12pt monospaced system line out at; the rest of the line height is
    /// added as spacing so the block is as tall as computed.
    private static let naturalLineHeight: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: ChatMetrics.codeFontSize, weight: .regular)
        return NSLayoutManager().defaultLineHeight(for: font)
    }()
}
