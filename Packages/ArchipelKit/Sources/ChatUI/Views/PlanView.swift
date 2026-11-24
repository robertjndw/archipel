import ACPKit
import SwiftUI
import UISupport

/// The agent's plan as a pill above the composer: how far along it is and the step it is on.
/// Opens into the whole checklist.
struct PlanView: View {
    let entries: [PlanEntry]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool

    /// Previews pass `isExpanded` to start with the checklist open.
    init(entries: [PlanEntry], isExpanded: Bool = false) {
        self.entries = entries
        _isExpanded = State(initialValue: isExpanded)
    }

    private var completed: Int { entries.count { $0.status == .completed } }

    /// The step being worked on, or the next one up, or nothing once all are done.
    private var current: PlanEntry? {
        entries.first { $0.status == .inProgress } ?? entries.first { $0.status == .pending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.disclosure) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ProgressRing(fraction: Double(completed) / Double(max(entries.count, 1)))
                        .frame(width: 14, height: 14)
                    Text("\(completed) of \(entries.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if !isExpanded {
                        Text(verbatim: current?.content ?? "Plan complete")
                            .lineLimit(1)
                            .transition(.opacity)
                    } else {
                        Text("Plan")
                            .transition(.opacity)
                    }
                    DisclosureChevron(isExpanded: isExpanded)
                }
                .font(.callout)
                .frame(height: Self.pillHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Plan, \(completed) of \(entries.count) steps done")
            .accessibilityValue(isExpanded ? "Expanded" : (current?.content ?? "Complete"))
            .accessibilityIdentifier("chat.plan")

            if isExpanded {
                checklist
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        // Closed, the pill is as wide as its one line. Open, it has a width of its own, so long
        // steps wrap inside it instead of stretching it.
        .frame(maxWidth: isExpanded ? 440 : nil, alignment: .leading)
        .fixedSize(horizontal: !isExpanded, vertical: false)
        // The panel radius rather than a capsule: closed, it is more than half the pill's height,
        // so the pill is round at the ends anyway; open, a capsule would keep rounding the whole
        // side as the checklist grows.
        .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.panel))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let pillHeight: CGFloat = 30

    private var checklist: some View {
        CappedHeight(maximum: 220) {
            ScrollView { steps }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: entry.status))
                        .foregroundStyle(entry.status == .inProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 14)
                    Text(verbatim: entry.content)
                        .fontWeight(entry.status == .inProgress ? .medium : .regular)
                        .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.content), \(spokenStatus(entry.status))")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbol(for status: PlanEntryStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        case .pending: "circle"
        }
    }

    private func spokenStatus(_ status: PlanEntryStatus) -> String {
        switch status {
        case .completed: "done"
        case .inProgress: "in progress"
        case .pending: "to do"
        }
    }
}

/// A small ring that fills clockwise from the top.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.secondary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}
