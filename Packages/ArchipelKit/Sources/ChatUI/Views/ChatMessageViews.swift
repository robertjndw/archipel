import ACPKit
import AppKit
import EditorUI
import SwiftUI
import UISupport

// MARK: User

/// The user's prompt: right-aligned in the one filled shape of the transcript.
struct UserMessageView: View {
    let message: ChatMessage
    /// The widest the bubble gets, so a long prompt still reads as the user's side.
    let maximumWidth: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let chips = message.attachments.compactMap(AttachmentChip.Item.init(block:))
            if !chips.isEmpty {
                AttachmentFlow(items: chips, alignment: .trailing)
            }
            if !message.text.isEmpty {
                SearchableText(text: message.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quinary, in: .rect(cornerRadius: ChatMetrics.surfaceRadius, style: .continuous))
            }
        }
        .frame(maxWidth: maximumWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(message.text)")
        .accessibilityIdentifier("chat.message.user")
    }
}

// MARK: Agent

/// The agent's reply: Markdown straight on the page, as wide as the column.
struct AgentMessageView: View {
    let message: ChatMessage
    /// Keeps a line free under the reply for the Copy button, which shows on hover, so the button
    /// never moves anything. Only the reply that ends a turn gets it: between two tool calls the free
    /// line would tear the turn apart.
    let showsCopyButton: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var copied = false

    private static let spacing: CGFloat = 8
    private static let copyButtonSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            if !message.text.isEmpty {
                MarkdownText(message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let chips = message.attachments.compactMap(AttachmentChip.Item.init(block:))
            if !chips.isEmpty {
                AttachmentFlow(items: chips)
            }
            if showsCopyButton {
                copyButton
                    // Closer to the text than the other parts are to each other, by as much as
                    // makes the button's row the footer every finished reply has.
                    .padding(.top, ChatMetrics.replyFooterHeight - Self.copyButtonSize - Self.spacing)
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc", action: copy)
        }
        .accessibilityIdentifier("chat.message.agent")
    }

    private var copyButton: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: Self.copyButtonSize, height: Self.copyButtonSize)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy Message")
        .accessibilityIdentifier("chat.message.copy")
        // The glyph has room inside its hit area; pull it back so it lines up with the text.
        .padding(.leading, -4)
        .opacity(isHovered || copied ? 1 : 0)
        .animation(reduceMotion ? nil : Motion.hover, value: isHovered)
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
        pasteboard.setString(message.text, forType: .string)
        copied = true
    }
}

// MARK: Thought

/// The agent's thinking: one quiet line, which opens to show what it thought.
///
/// It reads "Thought" even while the thought is still coming in. A row records a step, as a tool
/// call's does while it runs, and the status line under the transcript says what is going on now.
/// "Thinking" twice in a row would look like a mistake.
struct ThoughtRow: View {
    let message: ChatMessage
    let isExpanded: Bool
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: ChatMetrics.symbolSpacing) {
                    Image(systemName: "brain")
                        .font(.system(size: 12))
                        .frame(width: ChatMetrics.symbolColumn)
                    Text("Thought")
                    DisclosureChevron(isExpanded: isExpanded)
                        .opacity(isHovered || isExpanded ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: ChatMetrics.activityRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thought")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : Motion.hover, value: isHovered)

            if isExpanded {
                SearchableText(text: message.text)
                    .font(.callout)
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, ChatMetrics.detailIndent)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }
}

/// Plain text of the transcript, with Find's hits marked while a search is on.
struct SearchableText: View {
    let text: String

    @Environment(\.textHighlight) private var highlight

    var body: some View {
        highlight.map { Text($0.apply(to: text)) } ?? Text(verbatim: text)
    }
}

// MARK: Working

/// The line at the end of the transcript while a turn runs: what the agent is doing right now
/// and, once the turn has gone on for a few seconds, for how long.
///
/// The words are the indicator: a band of light passes over them, with no spinner or dots.
struct WorkingStatusLine: View {
    /// What the turn is doing, from `WorkingStatus.phrase`.
    let phrase: String
    /// When the turn's working time began; nil leaves the time out.
    let anchor: Date?

    /// How long a phrase has to hold before it is shown. A run of quick tool calls would
    /// otherwise flicker through five phrases in a second.
    static let settleTime: Duration = .milliseconds(350)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: String

    init(phrase: String, anchor: Date?) {
        self.phrase = phrase
        self.anchor = anchor
        _shown = State(initialValue: phrase)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: shown)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(reduceMotion ? .identity : .interpolate)
                .shimmer()
            if let anchor {
                ElapsedTimeLabel(anchor: anchor)
            }
        }
        .font(.callout)
        .frame(height: ChatMetrics.activityRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: shown)
        .task(id: phrase) {
            guard phrase != shown else { return }
            // Stopping is the answer to a click, so it shows at once.
            if phrase != WorkingStatus.stopping {
                try? await Task.sleep(for: Self.settleTime)
                guard !Task.isCancelled else { return }
            }
            shown = phrase
        }
        .accessibilityElement(children: .combine)
        // The time changes by itself; VoiceOver reads it when asked instead of every second.
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("chat.working")
    }
}

/// The running turn's time, ticking once a second. Always laid out, so its fading in after the
/// first quiet seconds moves nothing, and never animated as it ticks.
private struct ElapsedTimeLabel: View {
    let anchor: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Ticks on the turn's own seconds, so the text changes exactly when a second is over.
        TimelineView(.periodic(from: anchor, by: 1)) { context in
            let seconds = ElapsedTime.seconds(since: anchor, at: context.date)
            let isShown = seconds >= ElapsedTime.quietSeconds
            Text(verbatim: ElapsedTime.text(seconds: seconds))
                .monospacedDigit()
                // Not tertiary: the time is what answers "is it stuck?", and has to be read.
                // The phrase beside it is told apart by its shimmer.
                .foregroundStyle(.secondary)
                .opacity(isShown ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: isShown)
                .accessibilityLabel(ElapsedTime.spoken(seconds: seconds))
                .accessibilityHidden(!isShown)
        }
    }
}

// MARK: Notes

/// Why the last turn stopped short, under the last message.
struct TurnErrorView: View {
    let message: String

    var body: some View {
        Label {
            Text(verbatim: message)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat.turnError")
    }
}

// MARK: Attachments

/// A file that went along with a message.
struct AttachmentChip: View {
    struct Item: Hashable {
        var name: String
        var symbol: String

        init(name: String, symbol: String) {
            self.name = name
            self.symbol = symbol
        }

        /// `FileSymbol` knows files by their names; a folder has to be told apart first.
        init(url: URL) {
            self.init(name: url.lastPathComponent, symbol: url.hasDirectoryPath ? Self.folderSymbol : FileSymbol.name(for: url.lastPathComponent))
        }

        /// In the composer, where two attachments can have one name: a second Package.swift
        /// is told from the first by the folder it is in.
        init(url: URL, among urls: [URL]) {
            self.init(url: url)
            name = Self.name(of: url, among: urls)
        }

        static func name(of url: URL, among urls: [URL]) -> String {
            let name = url.lastPathComponent
            guard urls.contains(where: { $0 != url && $0.lastPathComponent == name }) else { return name }
            let folder = url.deletingLastPathComponent().lastPathComponent
            return folder.isEmpty || folder == "/" ? name : "\(folder)/\(name)"
        }

        init?(block: ContentBlock) {
            switch block {
            case let .resourceLink(link):
                // A folder goes out as a link whose address ends in a slash, which is all that is
                // left of it once the prompt is sent.
                self.init(name: link.name, symbol: link.uri.hasSuffix("/") ? Self.folderSymbol : FileSymbol.name(for: link.name))
            case let .image(_, _, uri):
                let name = uri.flatMap(URL.init(string:))?.lastPathComponent
                self.init(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Image", symbol: "photo")
            case .audio:
                self.init(name: "Audio", symbol: "waveform")
            case let .resource(resource):
                let name = URL(string: resource.uri)?.lastPathComponent ?? resource.uri
                self.init(name: name, symbol: FileSymbol.name(for: name))
            case .text, .unknown:
                return nil
            }
        }

        private static let folderSymbol = "folder"
    }

    let item: Item
    /// Set in the composer, where an attachment can still be taken back.
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: item.symbol)
                .foregroundStyle(.secondary)
            Text(verbatim: item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(item.name)")
            }
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, remove == nil ? 8 : 5)
        .frame(height: 24)
        .frame(maxWidth: 220)
        .fixedSize()
        .background(.quinary, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
    }
}

/// Chips in rows that wrap, starting from the leading or the trailing edge.
struct AttachmentFlow: View {
    let items: [AttachmentChip.Item]
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        FlowLayout(spacing: 6, alignment: alignment) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                AttachmentChip(item: item)
            }
        }
    }
}

/// Lays subviews out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, extended > width {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
