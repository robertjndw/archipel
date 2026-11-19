import AgentKit
import ArchipelCore
import SwiftUI

/// The strip under the content area: subscription usage and the focused session's context on the
/// leading end, the agents across every island and the stay awake cup on the trailing end. It spans
/// the content column only, so the glass sidebar and the inspector keep running to the bottom of the
/// window.
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let settings = model.settings
        // The strip stays when every item is off: its height lines up with the island switcher.
        StatusBarStrip(items: AppSettings.StatusBarItem.allCases.filter(settings.shows)) { item in
            switch item {
            case .usage:
                // Once a minute is enough for "resets in" and for a window that has just reset.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    UsageItems(now: context.date)
                }
            case .context: ContextItem()
            case .agents: AgentsItem()
            case .resources: ResourcesItem()
            case .stayAwake: StayAwakeButton()
            }
        }
        .frame(height: 2 * Chrome.bottomLineInset)
        .background(Chrome.windowSurface)
        // Over the whole strip, so a right-click between the items gets the menu too, as it does on
        // the menu bar or a toolbar.
        .accessibilityElement(children: .contain)
        .statusBarMenu(settings) {
            SettingsView.select(.appearance)
            openSettings()
        }
        .animation(reduceMotion ? nil : Motion.disclosure, value: settings.hiddenStatusBarItems)
        .padding(.top, -Chrome.statusBarOverlap(for: model.settings.paneStyle))
    }
}

/// The status bar's layout without its data, shared with the live preview in Settings so the two
/// cannot drift apart.
struct StatusBarStrip<Item: View>: View {
    let items: [AppSettings.StatusBarItem]
    @ViewBuilder let item: (AppSettings.StatusBarItem) -> Item

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 14) {
                ForEach(items.filter(\.isLeading)) { entry in
                    item(entry).transition(Self.transition)
                }
            }
            Spacer(minLength: 8)
            ForEach(items.filter { !$0.isLeading }) { entry in
                item(entry)
                    // Room rather than a hairline between the agents and the machine's items.
                    .padding(.trailing, entry == .agents ? 6 : 0)
                    .transition(Self.transition)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        // Extra room at the edges because the window's bottom corners are rounded.
        .padding(.horizontal, 14)
    }

    private static var transition: AnyTransition { .opacity.combined(with: .scale(scale: 0.8)) }
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
        .help("Show Usage Details")
        .accessibilityIdentifier("statusBar.usage")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            UsageDetails(readings: readings)
        }
    }
}

struct UsageItem: View {
    let reading: ProviderUsage
    let now: Date
    let display: AppSettings.UsageDisplay
    let fill: AppSettings.UsageBarFill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(symbol: reading.provider.symbolName)
            switch display {
            case .numbers:
                ForEach(reading.windows, id: \.windowMinutes) { window in
                    let percent = window.usedPercent(at: now)
                    HStack(spacing: 3) {
                        Text(window.shortLabel)
                            .foregroundStyle(.tertiary)
                        Text("\(Int(percent.rounded()))%")
                            .foregroundStyle(UsageColor.style(for: percent, calm: .secondary))
                            .contentTransition(.numericText(value: percent.rounded()))
                            .animation(reduceMotion ? nil : Motion.disclosure, value: Int(percent.rounded()))
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
        .help("\(reading.provider.displayName) usage")
        .accessibilityLabel("\(reading.provider.displayName) usage")
        .accessibilityValue(reading.windows.map { "\($0.longLabel) \(Int($0.usedPercent(at: now).rounded())) percent" }.joined(separator: ", "))
    }
}

private extension UsageProvider {
    /// The agent logo the sidebar uses.
    var symbolName: String {
        switch self {
        case .claude: AgentDefinition.claude.symbolName
        case .codex: AgentDefinition.codex.symbolName
        }
    }
}

/// A capsule filled to what is used, or to what is left. The color always follows what is used, so a
/// nearly empty "remaining" bar turns red just like a nearly full "used" one.
struct UsageBar: View {
    let usedPercent: Double
    let fill: AppSettings.UsageBarFill
    let height: CGFloat
    /// The fill below 75%. Subscription limits use the tint; the context stays neutral.
    var calm: AnyShapeStyle = AnyShapeStyle(.tint)

    var body: some View {
        let used = min(max(usedPercent, 0), 100)
        let filled = fill == .used ? used : 100 - used
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(UsageColor.style(for: used, calm: calm))
                        // A sliver at 0% would read as something being there, so an empty bar stays empty.
                        .frame(width: filled > 0 ? max(height, proxy.size.width * filled / 100) : 0)
                }
            }
            .frame(height: height)
            .animation(.smooth, value: filled)
    }
}

/// Orange from 75% and red from 90%, so a limit only stands out once it is worth watching.
enum UsageColor {
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
                // The status bar only shows the logo, so spell out the name here.
                Label(reading.provider.displayName, symbol: reading.provider.symbolName)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .contentTransition(.numericText(value: percent.rounded()))
                    .animation(reduceMotion ? nil : Motion.disclosure, value: Int(percent.rounded()))
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

    var body: some View {
        let summary = model.workspaceAttention
        Button {
            model.selectNextNeedingAttention()
        } label: {
            AgentsLabel(summary: summary)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Not disabled when nothing is waiting: that would dim the working count as well.
        .help(summary.needsAttention > 0 ? "Go to the next session waiting for you (⇧⌘U)" : "Agents in all islands")
        .accessibilityLabel("Agents")
        .accessibilityValue(summary.accessibilityDescription.isEmpty ? "None working" : summary.accessibilityDescription)
        .accessibilityIdentifier("statusBar.agents")
    }
}

struct AgentsLabel: View {
    let summary: AttentionSummary
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
                        .contentTransition(.numericText(value: Double(summary.working)))
                        .animation(reduceMotion ? nil : Motion.disclosure, value: summary.working)
                }
                .foregroundStyle(.secondary)
            }
            if summary.needsAttention > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("\(summary.needsAttention) waiting")
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: Double(summary.needsAttention)))
                        .animation(reduceMotion ? nil : Motion.disclosure, value: summary.needsAttention)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

#if DEBUG
private extension AppModel {
    static func previewNearLimit() -> AppModel {
        let model = AppModel.preview()
        model.usage = [
            .claude: ProviderUsage(
                provider: .claude,
                windows: [
                    UsageWindow(usedPercent: 96, windowMinutes: 300, resetsAt: .now.addingTimeInterval(40 * 60)),
                    UsageWindow(usedPercent: 78, windowMinutes: 7 * 24 * 60, resetsAt: .now.addingTimeInterval(2 * 86400)),
                ],
                updatedAt: .now
            ),
            .codex: ProviderUsage(
                provider: .codex,
                windows: [UsageWindow(usedPercent: 100, windowMinutes: 300, resetsAt: .now.addingTimeInterval(90 * 60))],
                updatedAt: .now.addingTimeInterval(-15 * 60)
            ),
        ]
        return model
    }
}

private func previewStatusBars() -> some View {
    // The fixture's focused Claude session is working, so its cache hides; this one has finished.
    let idle = AppModel.preview()
    idle.select(session: PreviewFixtures.reviewSessionID)
    let barsOnly = AppModel.preview()
    barsOnly.select(session: PreviewFixtures.reviewSessionID)
    barsOnly.settings.usageDisplay = .bars
    return VStack(spacing: 16) {
        StatusBar().environment(AppModel.preview())
        StatusBar().environment(idle)
        StatusBar().environment(barsOnly)
        StatusBar().environment(AppModel.previewNearLimit())
        StatusBar().environment(AppModel.emptyPreview())
    }
    .frame(width: 760)
    .padding(.vertical)
}

#Preview("Status Bar") {
    previewStatusBars()
}

#Preview("Status Bar, Dark") {
    previewStatusBars()
        .preferredColorScheme(.dark)
}

#Preview("Usage Items") {
    let low = PreviewFixtures.usage[.claude]!
    let high = AppModel.previewNearLimit().usage[.claude]!
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
            Text("Numbers").foregroundStyle(.secondary)
            UsageItem(reading: low, now: .now, display: .numbers, fill: .used)
            UsageItem(reading: high, now: .now, display: .numbers, fill: .used)
        }
        GridRow {
            Text("Bars, used").foregroundStyle(.secondary)
            UsageItem(reading: low, now: .now, display: .bars, fill: .used)
            UsageItem(reading: high, now: .now, display: .bars, fill: .used)
        }
        GridRow {
            Text("Bars, left").foregroundStyle(.secondary)
            UsageItem(reading: low, now: .now, display: .bars, fill: .remaining)
            UsageItem(reading: high, now: .now, display: .bars, fill: .remaining)
        }
    }
    .font(.system(size: 11))
    .padding()
}

#Preview("Usage Details") {
    let model = AppModel.preview()
    HStack(alignment: .top, spacing: 24) {
        UsageDetails(readings: UsageProvider.allCases.compactMap { model.usage[$0] })
        UsageDetails(readings: UsageProvider.allCases.compactMap { AppModel.previewNearLimit().usage[$0] })
        UsageDetails(readings: [])
    }
    .environment(model)
    .padding()
}
#endif
