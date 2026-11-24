import EditorUI
import SwiftUI

/// A compact unified diff of one edit: tinted lines, no line numbers, capped in height.
///
/// The diff comes from the chat's `DiffCache`; until it is ready, a placeholder of a few lines
/// stands in.
struct InlineDiffView: View, Equatable {
    let oldText: String?
    let newText: String
    var maximumHeight: CGFloat = 240
    /// Off where the diff already sits on a surface of its own, such as the permission card:
    /// a gray block on gray glass would be one layer too many.
    var showsBackground = true

    @Environment(\.chatDiffCache) private var cache

    nonisolated static func == (lhs: InlineDiffView, rhs: InlineDiffView) -> Bool {
        lhs.oldText == rhs.oldText && lhs.newText == rhs.newText && lhs.maximumHeight == rhs.maximumHeight
            && lhs.showsBackground == rhs.showsBackground
    }

    var body: some View {
        let entry = (cache ?? .fallback).entry(for: DiffCache.Key(oldText: oldText, newText: newText))
        Group {
            if let analysis = entry.analysis {
                diff(analysis)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .frame(height: min(Self.placeholderHeight, maximumHeight))
                    .accessibilityLabel("Loading changes")
            }
        }
        .background(showsBackground ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
        .clipShape(.rect(cornerRadius: ChatMetrics.blockRadius, style: .continuous))
    }

    private static var placeholderHeight: CGFloat {
        3 * ChatMetrics.codeLineHeight + verticalPadding * 2
    }

    private func diff(_ analysis: DiffAnalysis) -> some View {
        DiffLines(analysis: analysis, maximumHeight: maximumHeight)
    }

    fileprivate static let verticalPadding: CGFloat = 6
    fileprivate static let markerWidth: CGFloat = 24
}

/// The lines of a diff in their capped scroller. A view of its own for what Find needs of it:
/// the scroller's position, and the search to read.
private struct DiffLines: View {
    let analysis: DiffAnalysis
    let maximumHeight: CGFloat

    @Environment(\.textHighlight) private var highlight
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        let lines = analysis.lines
        let hidden = analysis.hiddenLineCount
        let rowCount = lines.count + (hidden > 0 ? 1 : 0)
        let height = CGFloat(rowCount) * ChatMetrics.codeLineHeight + InlineDiffView.verticalPadding * 2
        let shownHeight = min(height, maximumHeight)
        // The line Find is on. Lines that read alike share the mark, and the first is shown.
        let currentRow = highlight?.current.flatMap { current in lines.firstIndex { $0.kind != .gap && $0.text == current.text } }

        ScrollView(.vertical) {
            // The tints span the block and stay put; only the text scrolls sideways over them.
            // Tinting each line's own background would end at the line's last character.
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        DiffLineBackground(kind: line.kind)
                    }
                }
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            // Marks Find's hits; without a search it is the plain text it was.
                            SearchableText(text: line.text)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(height: ChatMetrics.codeLineHeight)
                        }
                        if hidden > 0 {
                            Text("\(hidden) more lines")
                                .foregroundStyle(.secondary)
                                .frame(height: ChatMetrics.codeLineHeight)
                        }
                    }
                    .font(ChatMetrics.codeFont)
                    .textSelection(.enabled)
                    .padding(.leading, InlineDiffView.markerWidth)
                    .padding(.trailing, 10)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            .padding(.vertical, InlineDiffView.verticalPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($position)
        // Also when the diff first shows: Find opens the row with the hit already current.
        .onChange(of: currentRow, initial: true) {
            guard let currentRow else { return }
            position.scrollTo(y: CodeBlockScroll.offset(centering: currentRow, padding: InlineDiffView.verticalPadding, blockHeight: shownHeight))
        }
        .frame(height: shownHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Changes: \(analysis.stats.added) lines added, \(analysis.stats.removed) removed")
    }
}

private struct DiffLineBackground: View {
    let kind: DiffLine.Kind

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(tint)
            Text(verbatim: marker)
                .font(ChatMetrics.codeFont)
                .foregroundStyle(kind == .gap ? .tertiary : .secondary)
                .frame(width: InlineDiffView.markerWidth)
        }
        .frame(height: ChatMetrics.codeLineHeight)
    }

    private var marker: String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .gap: "⋯"
        case .context: ""
        }
    }

    private var tint: Color {
        switch kind {
        case .added: .green.opacity(0.16)
        case .removed: .red.opacity(0.14)
        case .context, .gap: .clear
        }
    }
}

/// The added and removed lines of a call's edits, once they are counted. Nothing until then, and
/// "Large change" for files too long to compare.
struct DiffStatsBadge: View, Equatable {
    let diffs: [ToolCallDiff]

    @Environment(\.chatDiffCache) private var cache

    nonisolated static func == (lhs: DiffStatsBadge, rhs: DiffStatsBadge) -> Bool {
        lhs.diffs == rhs.diffs
    }

    var body: some View {
        let cache = cache ?? .fallback
        let analyses = diffs.map { cache.entry(for: DiffCache.Key(oldText: $0.oldText, newText: $0.newText)).analysis }
        if !analyses.isEmpty, analyses.allSatisfy({ $0 != nil }) {
            let ready = analyses.compactMap(\.self)
            if ready.contains(where: \.isApproximate) {
                Text("Large change")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                DiffStatsLabel(stats: ready.reduce(into: LineDiff.Stats(added: 0, removed: 0)) { total, analysis in
                    total.added += analysis.stats.added
                    total.removed += analysis.stats.removed
                })
            }
        }
    }
}

/// "+3 -1" for an edit, in the colors of the diff.
struct DiffStatsLabel: View {
    let stats: LineDiff.Stats

    var body: some View {
        HStack(spacing: 4) {
            if stats.added > 0 {
                Text(verbatim: "+\(stats.added)").foregroundStyle(.green)
            }
            if stats.removed > 0 {
                Text(verbatim: "-\(stats.removed)").foregroundStyle(.red)
            }
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stats.added) lines added, \(stats.removed) removed")
    }
}

#if DEBUG
#Preview("Diff") {
    InlineDiffView(
        oldText: "var isFormValid: Bool {\n    !email.isEmpty\n}\n",
        newText: "var isFormValid: Bool {\n    !email.isEmpty && !password.trimmingCharacters(in: .whitespaces).isEmpty\n}\n"
    )
    .padding(20)
    .frame(width: 420)
}
#endif
