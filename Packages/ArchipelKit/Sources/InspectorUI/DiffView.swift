import GitKit
import SwiftUI

struct DiffLine: Identifiable, Sendable {
    enum Kind: Sendable { case added, removed, header, context }

    let id: Int
    let text: String
    let kind: Kind
}

struct DiffView: View {
    let path: String
    let staged: Bool
    let root: URL

    @State private var lines: [DiffLine]?
    @State private var isTruncated = false
    @State private var error: String?

    /// SwiftUI text gets slow to scroll past this many lines, so larger diffs are cut off.
    private nonisolated static let maxLines = 5_000
    private nonisolated static let maxLineLength = 1_000

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((path as NSString).lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(staged ? "Staged" : "Working Tree")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 420, idealWidth: 620, minHeight: 280, idealHeight: 480)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView("Can't Show Diff", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let lines, lines.isEmpty {
            ContentUnavailableView("No Differences", systemImage: "doc.text.magnifyingglass")
        } else if let lines {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind.foreground)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind.background)
                    }
                    if isTruncated {
                        Text("Diff truncated after \(Self.maxLines) lines.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
            }
        } else {
            ProgressView()
        }
    }

    private func load() async {
        do {
            let diff = try await GitClient().diff(path: path, staged: staged, in: root)
            (lines, isTruncated) = await Self.parse(diff)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @concurrent
    private nonisolated static func parse(_ diff: String) async -> ([DiffLine], Bool) {
        var result: [DiffLine] = []
        var truncated = false
        // Outside a hunk every line is file metadata; inside one, a removed "-- comment" line is still a removal.
        var inHunk = false
        for (index, raw) in diff.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if index == maxLines {
                truncated = true
                break
            }
            let kind: DiffLine.Kind
            if raw.hasPrefix("diff ") {
                inHunk = false
                kind = .header
            } else if raw.hasPrefix("@@") {
                inHunk = true
                kind = .header
            } else if !inHunk || raw.hasPrefix("\\") {
                kind = .header
            } else if raw.hasPrefix("+") {
                kind = .added
            } else if raw.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            let text = raw.count > maxLineLength ? String(raw.prefix(maxLineLength)) + "..." : String(raw)
            result.append(DiffLine(id: index, text: text, kind: kind))
        }
        if result.last?.text.isEmpty == true { result.removeLast() }
        return (result, truncated)
    }
}

private extension DiffLine.Kind {
    var foreground: Color {
        switch self {
        case .added: .green
        case .removed: .red
        case .header: .secondary
        case .context: .primary
        }
    }

    var background: Color {
        switch self {
        case .added: .green.opacity(0.1)
        case .removed: .red.opacity(0.1)
        case .header, .context: .clear
        }
    }
}
