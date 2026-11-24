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
                Text(verbatim: message.text)
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
    /// Keeps a line free under the reply for the Copy button, which shows on hover. Reserving it
    /// means the button never moves anything, and it is only done for the reply that ends a turn:
    /// between two tool calls the free line would tear the turn apart.
    let showsCopyButton: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .padding(.top, -4)
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
                .frame(width: 22, height: 22)
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

/// The agent thinking: one quiet line, which opens to show what it thought.
struct ThoughtRow: View {
    let message: ChatMessage
    let isStreaming: Bool
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
                    Text(isStreaming ? "Thinking…" : "Thought")
                        .modifier(Pulse(isActive: isStreaming && !reduceMotion))
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
            .accessibilityLabel(isStreaming ? "Thinking" : "Thought")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : Motion.hover, value: isHovered)

            if isExpanded {
                Text(verbatim: message.text)
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

/// A slow breath for a label whose work is still going on.
private struct Pulse: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.phaseAnimator([1.0, 0.45]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        } else {
            content
        }
    }
}

// MARK: Working

/// Shown at the end of the transcript while the agent is busy and nothing else on screen says so.
struct WorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(.secondary)
            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: !reduceMotion)
            .frame(height: ChatMetrics.activityRowHeight)
            .accessibilityLabel("Working")
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

        init(url: URL) {
            self.init(name: url.lastPathComponent, symbol: FileSymbol.name(for: url.lastPathComponent))
        }

        init?(block: ContentBlock) {
            switch block {
            case let .resourceLink(link):
                self.init(name: link.name, symbol: FileSymbol.name(for: link.name))
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
