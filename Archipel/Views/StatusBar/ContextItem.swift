import AgentKit
import ArchipelCore
import SwiftUI

/// How full the focused Claude session's context window is, and how long its prompt cache stays
/// warm. Nothing at all for other tabs and before the first reply, since a guess would look like a
/// measurement.
struct ContextItem: View {
    @Environment(AppModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        if let id = model.focusedSessionID, let context = model.sessionContexts[id] {
            let settings = model.settings
            // While Claude works every request refreshes the cache anyway, so a countdown is noise.
            let cache = model.activity(for: id).isBusy ? nil : model.promptCaches[id]
            Button {
                showsDetails.toggle()
            } label: {
                ContextLabel(usedPercent: context.usedPercent, cache: cache, display: settings.usageDisplay, fill: settings.usageBarFill)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show Context Details")
            .accessibilityIdentifier("statusBar.context")
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                ContextDetails(sessionID: id)
            }
        }
    }
}

/// The ring and the cache countdown from values only, so the Settings preview can draw it too.
struct ContextLabel: View {
    let usedPercent: Double
    /// Nil when the cache is unknown or not worth a countdown right now.
    let cache: PromptCacheState?
    let display: AppSettings.UsageDisplay
    let fill: AppSettings.UsageBarFill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let percent = Int(usedPercent.rounded())
        TimelineView(CacheCountdown.schedule(for: cache, from: .now)) { timeline in
            let countdown = cache.map { CacheCountdown(cache: $0, now: timeline.date) }
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    // Percentages show the number used, so the ring follows it. Only bars have a fill setting.
                    ContextRing(usedPercent: usedPercent, fill: display == .bars ? fill : .used)
                    if display == .numbers {
                        Text("\(percent)%")
                            .foregroundStyle(UsageColor.style(for: usedPercent, calm: .secondary))
                            .contentTransition(.numericText(value: Double(percent)))
                            .animation(reduceMotion ? nil : Motion.disclosure, value: percent)
                    }
                }
                if let countdown {
                    if countdown.isWarm {
                        HStack(spacing: 3) {
                            Image(systemName: "timer")
                            Text(countdown.shortText)
                                .contentTransition(.numericText(countsDown: true))
                                .animation(reduceMotion ? nil : Motion.disclosure, value: countdown.shortText)
                        }
                        .foregroundStyle(countdown.isRunningOut ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    } else {
                        Text("Cache expired")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context")
            .accessibilityValue(["\(percent) percent", countdown?.spokenText].compactMap(\.self).joined(separator: ", "))
        }
    }
}

/// A ring the size of the status bar's capital letters, filled the way the usage bars are. Neutral
/// until it is worth watching: the tint is kept for what wants attention.
struct ContextRing: View {
    let usedPercent: Double
    let fill: AppSettings.UsageBarFill
    var diameter: CGFloat = 9
    var lineWidth: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let used = min(max(usedPercent, 0), 100)
        let filled = fill == .used ? used : 100 - used
        ZStack {
            Circle()
                .strokeBorder(.quaternary, lineWidth: lineWidth)
            // A round cap would draw a dot at 0%, which reads as something being there.
            if filled > 0 {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: filled / 100)
                    .stroke(UsageColor.style(for: used, calm: .secondary), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .smooth, value: filled)
    }
}

/// What is left of a warm cache, in the words the status bar and VoiceOver use.
struct CacheCountdown {
    let cache: PromptCacheState
    let now: Date

    var isWarm: Bool { cache.isWarm(at: now) }
    private var remaining: TimeInterval { cache.expiresAt.timeIntervalSince(now) }

    /// The last five minutes of an hour, or the last one of five: late enough that it only shows
    /// when a reply soon still saves the rebuild.
    var isRunningOut: Bool {
        isWarm && remaining <= (cache.ttl >= 3600 ? 5 * 60 : 60)
    }

    var shortText: String {
        remaining > 60 ? "\(Int((remaining / 60).rounded(.up))) min" : "\(Int(remaining.rounded(.up))) sec"
    }

    var spokenText: String {
        guard isWarm else { return "cache expired" }
        let left = remaining > 60
            ? Duration.seconds(60 * (remaining / 60).rounded(.up)).formatted(.units(allowed: [.minutes], width: .wide))
            : Duration.seconds(remaining.rounded(.up)).formatted(.units(allowed: [.seconds], width: .wide))
        return "cache expires in \(left)"
    }

    /// The moments the text changes: every minute counting back from the expiry, every second in
    /// the last one, and the expiry itself. Empty once it has passed, so an expired cache stops ticking.
    static func schedule(for cache: PromptCacheState?, from now: Date) -> ExplicitTimelineSchedule<[Date]> {
        guard let cache, cache.isWarm(at: now) else { return .explicit([]) }
        let expiry = cache.expiresAt
        let left = expiry.timeIntervalSince(now)
        let minutes = (1...max(1, Int(left / 60))).map { expiry.addingTimeInterval(-60 * Double($0)) }
        let seconds = (0..<60).map { expiry.addingTimeInterval(-Double($0)) }
        return .explicit((minutes + seconds).filter { $0 > now }.sorted())
    }
}

enum ContextFormat {
    /// "122k", "1M": the precision of a status line, not of a bill.
    static func tokens(_ count: Int) -> String {
        let thousands = Int((Double(count) / 1000).rounded())
        // Anything from 999,500 up would otherwise show as "1000k".
        if thousands >= 1000 {
            return (Double(count) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M"
        }
        if count >= 1000 { return "\(thousands)k" }
        return "\(count)"
    }

    /// For the tab's tooltip. The cache as a time rather than a countdown, since a tooltip does not tick.
    static func summary(of context: SessionContext, cache: PromptCacheState?, at now: Date) -> String {
        let percent = "Context \(Int(context.usedPercent.rounded()))% full"
        guard let cache else { return percent }
        let time = cache.expiresAt.formatted(date: .omitted, time: .shortened)
        return percent + (cache.isWarm(at: now) ? ", cache warm until \(time)" : ", cache expired at \(time)")
    }
}

/// What a click on the context shows: the session, its tokens, and its cache in plain words.
struct ContextDetails: View {
    @Environment(AppModel.self) private var model
    let sessionID: Session.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read live, so the popover keeps up with a turn that ends while it is open.
        if let context = model.sessionContexts[sessionID] {
            let cache = model.promptCaches[sessionID]
            let isWorking = model.activity(for: sessionID).isBusy
            let fill = model.settings.usageBarFill
            let percent = Int(context.usedPercent.rounded())
            TimelineView(.explicit(cache.map { [$0.expiresAt] } ?? [])) { timeline in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(model.workspace.session(id: sessionID)?.displayTitle ?? "Claude Code", symbol: AgentDefinition.claude.symbolName)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        if let name = context.model {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Context window")
                            Spacer()
                            Text(fill == .used ? "\(percent)% used" : "\(100 - percent)% left")
                                .monospacedDigit()
                                .foregroundStyle(UsageColor.style(for: context.usedPercent, calm: .primary))
                                .contentTransition(.numericText(value: Double(percent)))
                                .animation(reduceMotion ? nil : Motion.disclosure, value: percent)
                        }
                        .font(.callout)
                        UsageBar(usedPercent: context.usedPercent, fill: fill, height: 6, calm: AnyShapeStyle(.secondary))
                        Text("\(ContextFormat.tokens(context.usedTokens)) of \(ContextFormat.tokens(context.windowSize)) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let cache {
                        cacheDetails(cache, isWorking: isWorking, now: timeline.date)
                    }
                    Text("Compacting or switching models clears the cache, and Anthropic may drop it sooner.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(width: 320)
            }
        }
    }

    private func cacheDetails(_ cache: PromptCacheState, isWorking: Bool, now: Date) -> some View {
        let time = cache.expiresAt.formatted(date: .omitted, time: .shortened)
        let isWarm = isWorking || cache.isWarm(at: now)
        let ttl = Duration.seconds(cache.ttl).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        let (status, explanation) = if isWorking {
            ("Warm", "Every request keeps it warm while Claude works.")
        } else if isWarm {
            ("Warm until \(time)", "Kept for \(ttl) after each request.")
        } else {
            ("Expired at \(time)", "The next message rebuilds it.")
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Prompt cache")
                Spacer()
                Text(status)
                    .foregroundStyle(isWarm ? .primary : .secondary)
            }
            .font(.callout)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("Context Labels") {
    let warm = PromptCacheState(lastRequestAt: .now.addingTimeInterval(-12 * 60), ttl: 3600)
    let late = PromptCacheState(lastRequestAt: .now.addingTimeInterval(-57 * 60), ttl: 3600)
    let lastSeconds = PromptCacheState(lastRequestAt: .now.addingTimeInterval(-270), ttl: 300)
    let expired = PromptCacheState(lastRequestAt: .now.addingTimeInterval(-2 * 3600), ttl: 3600)
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
            Text("Numbers").foregroundStyle(.secondary)
            ContextLabel(usedPercent: 12, cache: warm, display: .numbers, fill: .used)
            ContextLabel(usedPercent: 78, cache: late, display: .numbers, fill: .used)
            ContextLabel(usedPercent: 94, cache: expired, display: .numbers, fill: .used)
        }
        GridRow {
            Text("Ring, used").foregroundStyle(.secondary)
            ContextLabel(usedPercent: 12, cache: lastSeconds, display: .bars, fill: .used)
            ContextLabel(usedPercent: 78, cache: nil, display: .bars, fill: .used)
            ContextLabel(usedPercent: 94, cache: expired, display: .bars, fill: .used)
        }
        GridRow {
            Text("Ring, left").foregroundStyle(.secondary)
            ContextLabel(usedPercent: 12, cache: warm, display: .bars, fill: .remaining)
            ContextLabel(usedPercent: 78, cache: nil, display: .bars, fill: .remaining)
            ContextLabel(usedPercent: 94, cache: expired, display: .bars, fill: .remaining)
        }
    }
    .font(.system(size: 11))
    .monospacedDigit()
    .padding()
}

#Preview("Context Details") {
    let model = AppModel.preview()
    HStack(alignment: .top, spacing: 24) {
        ContextDetails(sessionID: PreviewFixtures.reviewSessionID)
        ContextDetails(sessionID: PreviewFixtures.claudeSessionID)
        ContextDetails(sessionID: PreviewFixtures.idleSessionID)
    }
    .environment(model)
    .padding()
}
#endif
