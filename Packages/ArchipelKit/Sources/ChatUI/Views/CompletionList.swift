import ACPKit
import SwiftUI
import UISupport

/// One thing a completion list offers: a slash command, or a file to mention.
struct CompletionRow: Identifiable, Equatable {
    let id: String
    /// Files show theirs; commands have none.
    var symbol: String?
    var title: String
    var detail: String
    /// Where a title too long for the row gives way.
    var titleTruncation: Text.TruncationMode = .tail
    var detailTruncation: Text.TruncationMode = .tail
    var accessibilityLabel: String

    init(command: AvailableCommand) {
        let name = SlashCommands.displayName(command)
        id = command.id
        title = "/\(name)"
        detail = command.description
        accessibilityLabel = "\(name), \(command.description)"
    }

    init(file: FileMention) {
        id = file.id
        symbol = file.isDirectory ? "folder" : FileSymbol.name(for: file.name)
        title = file.name
        detail = file.folder
        // A name keeps its extension, and a path the folders nearest the file, which say most.
        titleTruncation = .middle
        detailTruncation = .head
        let kind = file.isDirectory ? "folder" : "file"
        accessibilityLabel = file.folder.isEmpty ? "\(file.name), \(kind)" : "\(file.name), \(kind) in \(file.folder)"
    }
}

/// What matches the text being typed, floating above the composer: the agent's slash commands
/// behind a "/", the worktree's files behind an "@". The keyboard stays in the composer; this
/// only shows the selection and takes clicks.
struct CompletionList: View {
    enum Kind {
        case commands
        case files

        var label: String {
            switch self {
            case .commands: "Commands"
            case .files: "Files"
            }
        }

        var identifier: String {
            switch self {
            case .commands: "chat.commands"
            case .files: "chat.mentions"
            }
        }
    }

    /// What VoiceOver is told about the list. The keyboard and with it VoiceOver's cursor stay
    /// in the composer, so nothing would otherwise say that a list opened over the text, that
    /// the arrows move through it, or which row Return is about to choose.
    struct Announcement: Equatable {
        var kind: Kind
        /// The selected row's label.
        var row: String
        var index: Int
        var count: Int

        /// Nil for a list without rows, which is not shown.
        init?(kind: Kind, rows: [CompletionRow], selection: Int) {
            guard rows.indices.contains(selection) else { return nil }
            self.kind = kind
            row = rows[selection].accessibilityLabel
            index = selection
            count = rows.count
        }

        /// "Files: ChatView.swift, file in Sources/ChatUI, 1 of 12". The kind is only said when
        /// the list opens; after that every move would repeat it.
        func text(isOpening: Bool) -> String {
            let place = "\(row), \(index + 1) of \(count)"
            return isOpening ? "\(kind.label): \(place)" : place
        }
    }

    let kind: Kind
    let rows: [CompletionRow]
    let selection: Int
    /// Called with the index of the row that was clicked.
    let choose: @MainActor (Int) -> Void

    private static let rowHeight: CGFloat = 30
    private static let inset: CGFloat = 6
    private static let visibleRows: CGFloat = 7
    private static let detailFloor: CGFloat = 72
    private static let radius = ChatMetrics.surfaceRadius

    /// Known without measuring, so the composer can place the list above itself.
    static func height(for count: Int) -> CGFloat {
        min(CGFloat(count), visibleRows) * rowHeight + inset * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: Claude sends about 135 commands, and the list opens on every "/".
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        self.row(row, at: index)
                            .id(row.id)
                    }
                }
                .padding(Self.inset)
            }
            .onChange(of: selection) { reveal(selection, with: proxy) }
            // Other matches after another keystroke: scrolled down among the old ones, the
            // selection would be out of sight.
            .onChange(of: rows) { reveal(selection, with: proxy) }
        }
        .frame(maxWidth: 460)
        .frame(height: Self.height(for: rows.count))
        .glassEffect(.regular, in: .rect(cornerRadius: Self.radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.label)
        .accessibilityIdentifier(kind.identifier)
    }

    private func reveal(_ index: Int, with proxy: ScrollViewProxy) {
        guard rows.indices.contains(index) else { return }
        proxy.scrollTo(rows[index].id)
    }

    private func row(_ row: CompletionRow, at index: Int) -> some View {
        let isSelected = index == selection
        return Button {
            choose(index)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: ChatMetrics.symbolSpacing) {
                    if let symbol = row.symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: ChatMetrics.symbolColumn)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: row.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(row.titleTruncation)
                }
                .layoutPriority(1)
                Text(verbatim: row.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(row.detailTruncation)
                    // A long name would otherwise leave the folder one clipped letter, which is
                    // neither a path nor nothing. This much of it can be read.
                    .frame(minWidth: row.detail.isEmpty ? 0 : Self.detailFloor, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .background {
                if isSelected {
                    // Concentric with the panel: its radius less the inset.
                    RoundedRectangle(cornerRadius: CornerRadius.concentric(Self.radius, inset: Self.inset), style: .continuous)
                        .fill(.quaternary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(kind.identifier).row")
    }
}

#if DEBUG
#Preview("Files") {
    CompletionList(
        kind: .files,
        rows: FileMentions.candidates(fromFiles: ChatSession.previewFiles).filter { $0.path.contains("Login") }.map(CompletionRow.init(file:)),
        selection: 1, choose: { _ in }
    )
    .padding(24)
    .frame(width: 520)
}

#Preview("Commands") {
    CompletionList(
        kind: .commands,
        rows: [
            AvailableCommand(name: "compact", description: "Summarize the conversation so far"),
            AvailableCommand(name: "review", description: "Review the changes on this branch"),
            AvailableCommand(name: "security-review", description: "Look for vulnerabilities in the pending changes"),
        ].map(CompletionRow.init(command:)),
        selection: 0, choose: { _ in }
    )
    .padding(24)
    .frame(width: 520)
}
#endif
