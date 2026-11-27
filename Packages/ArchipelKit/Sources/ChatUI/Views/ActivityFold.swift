import ACPKit
import SwiftUI
import UISupport

/// A finished stretch of looking around (commands, reads, searches, thoughts) drawn as one line
/// that opens: "Ran 9 commands, read 2 files". What the agent changed stays out of it, so edits
/// are always on the page.
struct ActivityFold: Equatable, Sendable {
    /// A shorter stretch stays as it is. Folding two lines into one saves a line and hides
    /// both.
    static let minimumSteps = 3

    /// Named after the first step, like a tool group, with a prefix that keeps it apart from
    /// the step's own row.
    var id: String
    /// The transcript items inside, in order.
    var itemIDs: [String]
    var summary: String
    var symbolName: String
    var isOpen: Bool

    init(items: [ChatItem], isOpen: Bool) {
        id = Self.id(firstItemID: items.first?.id ?? "")
        itemIDs = items.map(\.id)
        (summary, symbolName) = Self.describe(items)
        self.isOpen = isOpen
    }

    static func id(firstItemID: String) -> String {
        "fold:\(firstItemID)"
    }

    /// Whether `item` is a step a fold may hold. A call that is still running or waiting stays
    /// on the page, and so does anything that changes files or asks for a decision.
    static func canHold(_ item: ChatItem) -> Bool {
        switch item {
        case .agentThought:
            return true
        case let .toolCall(call):
            // Subagents stay visible like edits do, and so does a shell while it still runs in
            // the background.
            guard call.status.isFinished, call.diffs.isEmpty, !call.startsSubagent, !call.isRunningInBackground else { return false }
            switch call.kind {
            case .read, .search, .execute, .think, .fetch, .other: return true
            case .edit, .delete, .move, .switchMode: return false
            }
        case .userMessage, .agentMessage:
            return false
        }
    }

    private enum Step: CaseIterable {
        case command, read, search, fetch, tool, thought

        init(_ kind: ToolKind) {
            switch kind {
            case .execute: self = .command
            case .read: self = .read
            case .search: self = .search
            case .fetch: self = .fetch
            case .think: self = .thought
            case .edit, .delete, .move, .switchMode, .other: self = .tool
            }
        }

        var symbolName: String {
            switch self {
            case .command: ToolKind.execute.symbolName
            case .read: ToolKind.read.symbolName
            case .search: ToolKind.search.symbolName
            case .fetch: ToolKind.fetch.symbolName
            case .tool: ToolKind.other.symbolName
            case .thought: ToolKind.think.symbolName
            }
        }

        func phrase(_ count: Int) -> String {
            let one = count == 1
            return switch self {
            case .command: one ? "ran 1 command" : "ran \(count) commands"
            case .read: one ? "read 1 file" : "read \(count) files"
            case .search: one ? "searched once" : "searched \(count) times"
            case .fetch: one ? "fetched 1 page" : "fetched \(count) pages"
            case .tool: one ? "used 1 tool" : "used \(count) tools"
            case .thought: one ? "thought once" : "thought \(count) times"
            }
        }
    }

    /// The line a closed fold shows, and the symbol of what it mostly holds.
    static func describe(_ items: [ChatItem]) -> (summary: String, symbolName: String) {
        var counts: [Step: Int] = [:]
        var order: [Step] = []
        var failed = 0
        for item in items {
            let step: Step
            switch item {
            case .agentThought:
                step = .thought
            case let .toolCall(call):
                step = Step(call.kind)
                if call.status == .failed { failed += 1 }
            case .userMessage, .agentMessage:
                continue
            }
            if counts[step] == nil { order.append(step) }
            counts[step, default: 0] += 1
        }
        // Thoughts are only mentioned when the fold holds nothing else.
        if order.count > 1 { order.removeAll { $0 == .thought } }
        // Most frequent first; `order` breaks ties by which came first.
        let ranked = order.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (counts[lhs.element] ?? 0, counts[rhs.element] ?? 0)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
        var parts = ranked.map { $0.phrase(counts[$0] ?? 0) }
        if failed > 0 { parts.append("\(failed) failed") }
        let text = parts.joined(separator: ", ")
        return (text.prefix(1).uppercased() + text.dropFirst(), (ranked.first ?? .tool).symbolName)
    }
}

/// The line of a fold. Its steps are rows of their own under it while it is open.
struct ActivityFoldRow: View {
    let fold: ActivityFold
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: ChatMetrics.symbolSpacing) {
                Image(systemName: fold.symbolName)
                    .font(.system(size: 12))
                    .frame(width: ChatMetrics.symbolColumn)
                Text(fold.summary)
                    .lineLimit(1)
                // Always there, unlike a tool call's: nothing else says this line holds more.
                DisclosureChevron(isExpanded: fold.isOpen)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(height: ChatMetrics.activityRowHeight)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: ChatMetrics.blockRadius, style: .continuous)
                    .fill(.quinary)
                    .padding(.horizontal, -6)
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fold.summary)
        .accessibilityValue(fold.isOpen ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("chat.activityFold")
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Motion.hover, value: isHovered)
    }
}
