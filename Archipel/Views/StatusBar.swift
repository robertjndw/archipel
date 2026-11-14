import ArchipelCore
import SwiftUI

/// The strip under the content area: subscription usage on the leading end, the agents across every
/// island and the stay awake cup on the trailing end. It spans the content column only, so the glass
/// sidebar and the inspector keep running to the bottom of the window.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            // Once a minute is enough for "resets in" and for a window that has just reset.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                UsageItems(now: context.date)
            }
            Spacer(minLength: 8)
            AgentsItem()
            StayAwakeButton()
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct UsageItems: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @State private var showsDetails = false

    var body: some View {
        let readings = UsageProvider.allCases.compactMap { model.usage[$0] }
        Button {
            showsDetails.toggle()
        } label: {
            Group {
                if readings.isEmpty {
                    Text("Usage shows up after the first agent reply")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 14) {
                        ForEach(readings, id: \.provider) { reading in
                            UsageItem(reading: reading, now: now, display: model.settings.usageDisplay, fill: model.settings.usageBarFill)
                        }
                    }
                }
            }
            // A plain button only takes clicks on drawn pixels, and the bars are a few points tall with
            // gaps between them. The shape has to sit on the label, not the button, and spans the
            // bar's full height so the whole strip around the usage is clickable.
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show usage details")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            UsageDetails(readings: readings)
        }
    }
}

private struct UsageItem: View {
    let reading: ProviderUsage
    let now: Date
    let display: AppSettings.UsageDisplay
    let fill: AppSettings.UsageBarFill

    var body: some View {
        HStack(spacing: 6) {
            Text(reading.provider.displayName)
                .foregroundStyle(.secondary)
            switch display {
            case .numbers:
                ForEach(reading.windows, id: \.windowMinutes) { window in
                    let percent = window.usedPercent(at: now)
                    HStack(spacing: 3) {
                        Text(window.shortLabel)
                            .foregroundStyle(.tertiary)
                        Text("\(Int(percent.rounded()))%")
                            .foregroundStyle(UsageColor.style(for: percent, calm: .secondary))
                    }
                }
            case .bars:
                // Stacked like CodexBar's icon: the short window on top, a little thicker since it is
                // the one you hit first.
                VStack(spacing: 2) {
                    ForEach(Array(reading.windows.enumerated()), id: \.element.windowMinutes) { index, window in
                        UsageBar(usedPercent: window.usedPercent(at: now), fill: fill, height: index == 0 ? 4 : 3)
                    }
                }
                .frame(width: 44)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.provider.displayName) usage")
        .accessibilityValue(reading.windows.map { "\($0.longLabel) \(Int($0.usedPercent(at: now).rounded())) percent" }.joined(separator: ", "))
    }
}

/// A capsule filled to what is used, or to what is left. The color always follows what is used, so a
/// nearly empty "remaining" bar turns red just like a nearly full "used" one.
private struct UsageBar: View {
    let usedPercent: Double
    let fill: AppSettings.UsageBarFill
    let height: CGFloat

    var body: some View {
        let used = min(max(usedPercent, 0), 100)
        let filled = fill == .used ? used : 100 - used
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(UsageColor.style(for: used, calm: .tint))
                        // A sliver at 0% would read as something being there, so an empty bar stays empty.
                        .frame(width: filled > 0 ? max(height, proxy.size.width * filled / 100) : 0)
                }
            }
            .frame(height: height)
            .animation(.smooth, value: filled)
    }
}

/// Orange from 75% and red from 90%, so a limit only stands out once it is worth watching.
private enum UsageColor {
    static func style(for percent: Double, calm: some ShapeStyle) -> AnyShapeStyle {
        switch percent {
        case 90...: AnyShapeStyle(.red)
        case 75...: AnyShapeStyle(.orange)
        default: AnyShapeStyle(calm)
        }
    }
}

/// What a click on the usage shows: every window, when it resets, and whether the current pace runs out before then.
private struct UsageDetails: View {
    @Environment(AppModel.self) private var model
    let readings: [ProviderUsage]

    var body: some View {
        let settings = model.settings
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 14) {
                if readings.isEmpty {
                    Text("No usage yet")
                        .font(.headline)
                    Text("Claude reports its limits once a session has answered, Codex after its first turn. Accounts that pay per token have no limits to show.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Codex writes its limits to disk, so they can be looked for without a running session.
                    Button("Check Codex Again") { model.refreshCodexUsage() }
                        .buttonStyle(.link)
                } else {
                    ForEach(readings, id: \.provider) { reading in
                        ProviderDetails(reading: reading, now: context.date, fill: settings.usageBarFill)
                        if reading.provider != readings.last?.provider { Divider() }
                    }
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

private struct ProviderDetails: View {
    @Environment(AppModel.self) private var model
    let reading: ProviderUsage
    let now: Date
    let fill: AppSettings.UsageBarFill
    @State private var refreshes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(reading.provider.displayName)
                    .font(.headline)
                Spacer()
                Text("Updated \(reading.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                // Only Codex: Claude's numbers come in live through its status line and have nothing to re-read.
                if reading.provider == .codex {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        refreshes += 1
                        model.refreshCodexUsage()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.rotate, value: refreshes)
                    .help("Read Codex's limits from its latest session logs again")
                }
            }
            ForEach(reading.windows, id: \.windowMinutes) { window in
                WindowDetails(window: window, now: now, fill: fill)
            }
        }
    }
}

private struct WindowDetails: View {
    let window: UsageWindow
    let now: Date
    let fill: AppSettings.UsageBarFill

    var body: some View {
        let percent = window.usedPercent(at: now)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(window.longLabel) limit")
                Spacer()
                // Says the same thing the bar below shows.
                Text(fill == .used ? "\(Int(percent.rounded()))% used" : "\(Int((100 - percent).rounded()))% left")
                    .monospacedDigit()
                    .foregroundStyle(UsageColor.style(for: percent, calm: .primary))
            }
            .font(.callout)
            UsageBar(usedPercent: percent, fill: fill, height: 6)
                .overlay(alignment: .leading) { paceMarker }
            Group {
                if let reset = resetText { Text(reset) }
                if let pace { Text(pace.text).foregroundStyle(pace.runsOut ? .orange : .secondary) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// A tick where the bar would be if usage were spread evenly over the window. A used bar past it,
    /// or a remaining bar short of it, means the limit is going faster than it refills.
    @ViewBuilder private var paceMarker: some View {
        if let elapsed = window.elapsedFraction(at: now), elapsed > 0, elapsed < 1 {
            let position = fill == .used ? elapsed : 1 - elapsed
            GeometryReader { proxy in
                Rectangle()
                    .fill(.primary.opacity(0.5))
                    .frame(width: 1.5, height: 10)
                    .offset(x: proxy.size.width * position - 0.75, y: -2)
            }
            .help("Even pace: \(Int((elapsed * 100).rounded()))% of the window has passed")
        }
    }

    private var resetText: String? {
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        let relative = resetsAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
        let time = resetsAt.timeIntervalSince(now) < 20 * 60 * 60
            ? resetsAt.formatted(date: .omitted, time: .shortened)
            : resetsAt.formatted(.dateTime.weekday(.wide).hour().minute())
        return "Resets \(time), \(relative)"
    }

    private var pace: (text: String, runsOut: Bool)? {
        if let exhaustion = window.projectedExhaustion(at: now) {
            let relative = exhaustion.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            return ("At this pace it runs out \(relative), before the reset", true)
        }
        guard window.elapsedFraction(at: now) != nil, window.usedPercent(at: now) > 0 else { return nil }
        return ("At this pace it lasts until the reset", false)
    }
}

/// What every agent is doing, across all islands, not only the one on screen.
private struct AgentsItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let summary = attentionSummary(of: model.workspace, activities: model.activities)
        Button {
            model.selectNextNeedingAttention()
        } label: {
            HStack(spacing: 10) {
                if summary.working == 0, summary.needsAttention == 0 {
                    Text("No agents working")
                        .foregroundStyle(.tertiary)
                }
                if summary.working > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.tint)
                            .symbolEffect(.pulse, options: .repeating, isActive: appearsActive)
                        Text("\(summary.working) working")
                    }
                    .foregroundStyle(.secondary)
                }
                if summary.needsAttention > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text("\(summary.needsAttention) waiting")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Not disabled when nothing is waiting: that would dim the working count as well.
        .help(summary.needsAttention > 0 ? "Go to the next session waiting for you (⇧⌘U)" : "Agents in all islands")
        .accessibilityLabel("Agents")
        .accessibilityValue(summary.accessibilityDescription.isEmpty ? "None working" : summary.accessibilityDescription)
    }
}
