import ACPKit
import SwiftUI
import UISupport

/// The agent's settings under the composer's text. The mode, with a symbol of its own, and the
/// model are quiet menus showing the current choice. Whatever else the agent offers sits behind
/// one button, which shows the thinking effort as a gauge when there is one.
struct ChatControlsBar: View {
    let controls: [ChatControl]
    /// The models the user chose before with this agent, latest first. They stay at hand when
    /// the agent's list is too long to show whole.
    var recentModels: [String] = []
    let select: @MainActor (_ controlID: String, _ value: String) -> Void
    let setToggle: @MainActor (_ controlID: String, _ isOn: Bool) -> Void

    @State private var showsSettings = false

    /// What the bar itself shows when there is room. A lone extra setting joins the mode and the
    /// model, since a popover holding one row would only hide it. The effort never does: its
    /// slider needs the popover.
    private var inline: [ChatControl] {
        let primary = controls.filter(\.isPrimary)
        let rest = controls.filter { !$0.isPrimary }
        return rest.count == 1 && rest[0].levelScale == nil ? controls : primary
    }

    var body: some View {
        let inline = inline
        // A narrow pane shows fewer, the mode last to go; what does not fit moves behind the
        // settings button instead of being squeezed or cut off.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: inline.count, through: 0, by: -1)), id: \.self) { shown in
                row(inline.prefix(shown))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        // Each item has room around its label for the hover highlight. Taking that room back at
        // the leading edge keeps the first label in line with the text above.
        .padding(.leading, -BarItem.inset)
    }

    private func row(_ shown: ArraySlice<ChatControl>) -> some View {
        let rest = controls.filter { control in !shown.contains { $0.id == control.id } }
        return HStack(spacing: 0) {
            ForEach(shown) { control in
                ControlButton(control: control, recentModels: recentModels, select: select, setToggle: setToggle)
            }
            if !rest.isEmpty {
                Button {
                    showsSettings.toggle()
                } label: {
                    SettingsLabel(effort: rest.first { $0.levelScale != nil })
                }
                .buttonStyle(.plain)
                .barItem(isActive: showsSettings)
                .help("More Settings")
                .accessibilityLabel("More Settings")
                .accessibilityIdentifier("chat.control.more")
                .popover(isPresented: $showsSettings, arrowEdge: .top) {
                    ControlsPopover(controls: rest, recentModels: recentModels, select: select, setToggle: setToggle)
                }
            }
        }
    }
}

/// The settings button. With a thinking effort among the settings it is a gauge at that level
/// and the level's name, so the effort can be read without opening the popover.
private struct SettingsLabel: View {
    let effort: ChatControl?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let effort, let scale = effort.levelScale {
            let fraction = scale.fraction(of: effort)
            HStack(spacing: 4) {
                Image(systemName: ChatControl.LevelScale.gaugeSymbol(for: fraction))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                Text(verbatim: effort.currentChoiceName ?? scale.fallback?.name ?? effort.name)
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .interpolate)
            }
            .animation(reduceMotion ? nil : Motion.hover, value: fraction)
        } else {
            Image(systemName: "slider.horizontal.3")
        }
    }
}

/// The frame every item of the bar shares: room around the label, and a highlight under the
/// pointer or while the item's menu or popover is open, like a toolbar item's.
struct BarItem: ViewModifier {
    static let inset: CGFloat = 6

    var isActive = false

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Self.inset)
            .frame(height: 24)
            .contentShape(.rect)
            .background(
                .quaternary.opacity(isHovered || isActive ? 1 : 0),
                in: .rect(cornerRadius: CornerRadius.control, style: .continuous)
            )
            .fixedSize()
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : Motion.hover, value: isHovered || isActive)
    }
}

extension View {
    func barItem(isActive: Bool = false) -> some View {
        modifier(BarItem(isActive: isActive))
    }
}

/// The settings that are not in the bar, one row each: the name, then a switch or a menu of the
/// choices. It stays open, so several can be changed in one visit.
private struct ControlsPopover: View {
    let controls: [ChatControl]
    var recentModels: [String] = []
    let select: @MainActor (String, String) -> Void
    let setToggle: @MainActor (String, Bool) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            ForEach(controls) { control in
                GridRow {
                    if let scale = control.levelScale {
                        LevelSlider(control: control, scale: scale, select: select)
                            .gridCellColumns(2)
                    } else {
                        Text(verbatim: control.name)
                        field(for: control)
                            .gridColumnAlignment(.trailing)
                            .accessibilityLabel(control.name)
                            .accessibilityIdentifier("chat.control.\(control.id)")
                    }
                }
                .help(control.description ?? "")
            }
        }
        // A fixed width: the slider would otherwise take all the room a popover may have.
        .frame(width: 240)
        .padding(16)
    }

    @ViewBuilder private func field(for control: ChatControl) -> some View {
        switch control.value {
        case let .toggle(isOn):
            switchToggle(control.name, isOn: isOn) { setToggle(control.id, $0) }
        case let .select(current, _):
            if let values = control.switchValues {
                // Claude sends its on/off settings as a choice between "On" and "Off".
                switchToggle(control.name, isOn: current == values.on) {
                    select(control.id, $0 ? values.on : values.off)
                }
            } else {
                Menu(control.currentChoiceName ?? "") {
                    ControlChoices(control: control, recentModels: recentModels, select: select)
                }
                .fixedSize()
                .accessibilityValue(control.currentChoiceName ?? "")
            }
        }
    }

    private func switchToggle(_ name: String, isOn: Bool, set: @escaping @MainActor (Bool) -> Void) -> some View {
        Toggle(name, isOn: Binding(get: { isOn }, set: set))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

private struct ControlButton: View {
    let control: ChatControl
    var recentModels: [String] = []
    let select: @MainActor (String, String) -> Void
    let setToggle: @MainActor (String, Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch control.value {
        case let .select(current, _):
            let mode = control.currentModeStyle
            Menu {
                ControlChoices(control: control, recentModels: recentModels, select: select)
            } label: {
                HStack(spacing: 4) {
                    if let mode {
                        Image(systemName: mode.symbol)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                    Text(verbatim: control.barLabel)
                        .lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .interpolate)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                // Only a mode that lets the agent do anything unasked gets a color.
                .foregroundStyle(mode?.isUnrestricted == true ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .animation(reduceMotion ? nil : Motion.hover, value: current)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .barItem()
            .help(control.description ?? control.name)
            .accessibilityLabel(control.name)
            .accessibilityValue(control.currentChoiceName ?? "")
            .accessibilityIdentifier("chat.control.\(control.id)")
        case let .toggle(isOn):
            Button {
                setToggle(control.id, !isOn)
            } label: {
                Text(verbatim: control.barLabel)
                    .lineLimit(1)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .barItem()
            .help(control.description ?? control.name)
            .accessibilityLabel(control.name)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier("chat.control.\(control.id)")
        }
    }
}

extension ChatControl {
    /// The mode and the model are changed most often, so the bar always shows them.
    var isPrimary: Bool { category == .mode || category == .model }

    /// How a mode shows in the bar.
    struct ModeStyle: Equatable {
        var symbol: String
        /// The agent acts without asking and without a sandbox: Claude's bypass, Codex's full access.
        var isUnrestricted = false
    }

    /// Agents name their modes freely, so the symbol goes by the words they share. An unknown
    /// mode gets a neutral one rather than a guess.
    static func modeStyle(for choice: ConfigOptionValue) -> ModeStyle {
        let words = "\(choice.value) \(choice.name)".lowercased()
        func has(_ parts: String...) -> Bool { parts.contains { words.contains($0) } }
        if has("bypass", "full access", "full-access", "dontask", "don't ask", "yolo", "danger") {
            return ModeStyle(symbol: "exclamationmark.shield", isUnrestricted: true)
        }
        if has("plan") { return ModeStyle(symbol: "list.clipboard") }
        if has("read") { return ModeStyle(symbol: "eye") }
        if has("accept", "edit", "write", "workspace") { return ModeStyle(symbol: "pencil") }
        if has("auto") { return ModeStyle(symbol: "sparkles") }
        if has("build") { return ModeStyle(symbol: "hammer") }
        if has("default", "manual", "ask") { return ModeStyle(symbol: "hand.raised") }
        return ModeStyle(symbol: "switch.2")
    }

    /// Nil for anything but a mode with a current choice.
    var currentModeStyle: ModeStyle? {
        guard category == .mode, case let .select(current?, groups) = value,
              let choice = groups.lazy.flatMap(\.choices).first(where: { $0.value == current })
        else { return nil }
        return Self.modeStyle(for: choice)
    }

    /// The choice after the current one, the first after the last: what Shift-Tab moves the mode to.
    var nextChoice: ConfigOptionValue? {
        guard case let .select(current, groups) = value else { return nil }
        let choices = groups.flatMap(\.choices)
        guard choices.count > 1 else { return nil }
        guard let index = choices.firstIndex(where: { $0.value == current }) else { return choices.first }
        return choices[(index + 1) % choices.count]
    }

    /// The two values of a select that is really a switch: exactly two choices, "on" and "off".
    var switchValues: (on: String, off: String)? {
        guard case let .select(_, groups) = value else { return nil }
        let values = groups.flatMap(\.choices).map(\.value)
        guard values.count == 2,
              let on = values.first(where: { $0.caseInsensitiveCompare("on") == .orderedSame }),
              let off = values.first(where: { $0.caseInsensitiveCompare("off") == .orderedSame })
        else { return nil }
        return (on, off)
    }

    /// The choices of a setting that is a scale from little to much, in the agent's order.
    struct LevelScale: Equatable {
        var levels: [ConfigOptionValue]
        /// Claude's "Default": leaves the level to the agent, so it is not a stop on the scale.
        var fallback: ConfigOptionValue?
    }

    /// Set for the thinking effort when it has at least two levels to move between.
    var levelScale: LevelScale? {
        guard category == .thoughtLevel, case let .select(_, groups) = value else { return nil }
        let choices = groups.flatMap(\.choices)
        let fallback = choices.first { $0.value.caseInsensitiveCompare("default") == .orderedSame }
        let levels = choices.filter { $0.value != fallback?.value }
        return levels.count >= 2 ? LevelScale(levels: levels, fallback: fallback) : nil
    }

    /// A model list cut down to the few worth showing first.
    struct ModelShortlist: Equatable {
        /// In the agent's order, so a model keeps its place from one visit to the next.
        var shown: [ConfigOptionValue]
        /// Everything else, in the agent's groups.
        var others: [ChoiceGroup]
    }

    /// Nil unless this is a model list long enough that hiding part of it helps.
    ///
    /// An agent says nothing about a model's age or how much anyone uses it, so "the newest five"
    /// cannot be known. What can: the model in use, the ones the user chose before (`recent`,
    /// latest first), then the rest of the provider in use ("anthropic/…" in OpenCode), then
    /// whatever the agent lists first, which Claude and Codex order by recommendation.
    func modelShortlist(recent: [String], limit: Int = 5) -> ModelShortlist? {
        guard category == .model, case let .select(current, groups) = value else { return nil }
        let choices = groups.flatMap(\.choices)
        // Moving two or three models into a submenu saves nothing.
        guard choices.count >= limit + 4 else { return nil }
        let known = Set(choices.map(\.value))
        let provider = current.flatMap(Self.provider)
        let sameProvider = provider == nil ? [] : choices.map(\.value).filter { Self.provider(of: $0) == provider }
        var picked: [String] = []
        for value in [current].compactMap(\.self) + recent + sameProvider + choices.map(\.value)
        where picked.count < limit && known.contains(value) && !picked.contains(value) {
            picked.append(value)
        }
        let others = groups.compactMap { group -> ChoiceGroup? in
            let rest = group.choices.filter { !picked.contains($0.value) }
            return rest.isEmpty ? nil : ChoiceGroup(name: group.name, choices: rest)
        }
        // Each value once, should the agent list one twice.
        var seen = Set<String>()
        let shown = choices.filter { picked.contains($0.value) && seen.insert($0.value).inserted }
        return ModelShortlist(shown: shown, others: others)
    }

    /// "anthropic" of "anthropic/claude-fable-5", the way OpenCode names models.
    private static func provider(of value: String) -> String? {
        value.firstIndex(of: "/").map { String(value[..<$0]) }
    }

    /// A choice's description cut down to a menu item's subtitle: its first sentence, and no more
    /// than a line of it. Agents describe a persona in whole paragraphs.
    static func menuSummary(of description: String?, limit: Int = 60) -> String? {
        guard let line = description?.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        var summary = line.trimmingCharacters(in: .whitespaces)
        if let end = summary.range(of: ". ") {
            summary = String(summary[..<end.lowerBound])
        } else if summary.hasSuffix(".") {
            summary.removeLast()
        }
        guard !summary.isEmpty else { return nil }
        guard summary.count > limit else { return summary }
        // One more than the limit, so a word that ends exactly there counts as whole.
        let cut = summary.prefix(limit + 1)
        // Back to the last whole word, unless that would throw most of the line away.
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut.dropLast()
        let kept = words.count >= limit / 2 ? words : cut.dropLast()
        return kept.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// Claude's first model is "Default (recommended)" and says which one that is in the
    /// description. The bar shows the model.
    private var defaultModelName: String? {
        guard case let .select(current?, groups) = value, current.caseInsensitiveCompare("default") == .orderedSame,
              let description = groups.lazy.flatMap(\.choices).first(where: { $0.value == current })?.description?
              .trimmingCharacters(in: .whitespaces),
              !description.isEmpty, description.count <= 24, !description.contains(where: \.isNewline)
        else { return nil }
        return description
    }

    /// What the control's button says. The mode and the model are understood from the value
    /// alone; "Off" or "Default" next to them is not, so any other setting carries its name,
    /// unless the value already does ("Extended Thinking" for a control named "Thinking").
    var barLabel: String {
        switch value {
        case let .toggle(isOn):
            return "\(name): \(isOn ? "On" : "Off")"
        case .select:
            guard let choice = currentChoiceName else { return name }
            if category == .model, let model = defaultModelName { return model }
            if category == .mode || category == .model { return choice }
            if choice.localizedStandardContains(name) { return choice }
            return "\(name): \(choice)"
        }
    }
}

extension ChatControl.LevelScale {
    /// Where the control stands on the scale, from 0 at the lowest level to 1 at the highest.
    /// Nil while the agent uses its default.
    func fraction(of control: ChatControl) -> Double? {
        guard case let .select(current?, _) = control.value, let index = levels.firstIndex(where: { $0.value == current })
        else { return nil }
        return Double(index) / Double(levels.count - 1)
    }

    /// A gauge with its needle at the level. The default rests in the middle.
    static func gaugeSymbol(for fraction: Double?) -> String {
        let percent = switch fraction ?? 0.5 {
        case ..<0.17: 0
        case ..<0.42: 33
        case ..<0.59: 50
        case ..<0.84: 67
        default: 100
        }
        return "gauge.with.dots.needle.\(percent)percent"
    }
}

/// How hard the agent thinks, as a slider with a stop per level: the name and the chosen level
/// above, the track below, the way System Settings lays out its stepped sliders.
private struct LevelSlider: View {
    let control: ChatControl
    let scale: ChatControl.LevelScale
    let select: @MainActor (String, String) -> Void

    /// Where the thumb is. The agent's answer arrives a moment after a drag, and a thumb bound to
    /// the control alone would jump back to the old level until it does.
    @State private var position: Double?

    private var current: String? {
        guard case let .select(current, _) = control.value else { return nil }
        return current
    }

    private var currentIndex: Int? { scale.levels.firstIndex { $0.value == current } }

    var body: some View {
        // No level is chosen while the agent uses its default. The thumb then rests mid-track,
        // dimmed, and the label says what is in effect.
        let isUnset = currentIndex == nil && position == nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: control.name)
                Spacer(minLength: 12)
                Text(verbatim: valueName)
                    .foregroundStyle(.secondary)
                if let fallback = scale.fallback, current != fallback.value {
                    Button("Use \(fallback.name)", systemImage: "arrow.uturn.backward") {
                        position = nil
                        select(control.id, fallback.value)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Use \(fallback.name)")
                }
            }
            Slider(
                value: Binding(
                    get: { position ?? Double(currentIndex ?? (scale.levels.count - 1) / 2) },
                    set: { newValue in
                        let index = Int(newValue.rounded())
                        guard scale.levels.indices.contains(index) else { return }
                        let changed = position.map { Int($0) != index } ?? (currentIndex != index)
                        position = Double(index)
                        if changed { select(control.id, scale.levels[index].value) }
                    }
                ),
                in: 0...Double(scale.levels.count - 1),
                step: 1
            )
            .labelsHidden()
            .opacity(isUnset ? 0.5 : 1)
            // A haptic tick at each stop, on a Force Touch trackpad.
            .sensoryFeedback(.levelChange, trigger: position)
            .accessibilityLabel(control.name)
            .accessibilityValue(valueName)
            .accessibilityIdentifier("chat.control.\(control.id)")
        }
        // The agent has the last word, also when it refuses a level or changes it by itself.
        .onChange(of: current) { position = nil }
    }

    private var valueName: String {
        if let position, scale.levels.indices.contains(Int(position)) { return scale.levels[Int(position)].name }
        return control.currentChoiceName ?? scale.fallback?.name ?? ""
    }
}

/// The choices of one setting as menu items, the current one checked. A menu scrolls by itself,
/// but nobody reads 55 models to find the one they use: a long model list shows a handful and
/// keeps the rest one level down.
private struct ControlChoices: View {
    let control: ChatControl
    var recentModels: [String] = []
    let select: @MainActor (String, String) -> Void

    private var current: String? {
        guard case let .select(current, _) = control.value else { return nil }
        return current
    }

    var body: some View {
        if let shortlist = control.modelShortlist(recent: recentModels) {
            Section { items(shortlist.shown) }
            Menu("Other Models") { sections(shortlist.others) }
        } else if case let .select(_, groups) = control.value {
            sections(groups)
        }
    }

    private func sections(_ groups: [ChatControl.ChoiceGroup]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            if let name = group.name {
                Section(name) { items(group.choices) }
            } else {
                Section { items(group.choices) }
            }
        }
    }

    private func items(_ choices: [ConfigOptionValue]) -> some View {
        ForEach(choices, id: \.value) { choice in
            Toggle(isOn: Binding(
                get: { choice.value == current },
                // Choosing the checked item again turns the toggle "off"; there is nothing to do.
                set: { if $0 { select(control.id, choice.value) } }
            )) {
                if control.category == .mode {
                    // The same symbol the bar shows for the mode once it is chosen.
                    Label {
                        Text(verbatim: choice.name)
                    } icon: {
                        Image(systemName: ChatControl.modeStyle(for: choice).symbol)
                    }
                } else {
                    Text(verbatim: choice.name)
                }
                if let summary = ChatControl.menuSummary(of: choice.description) {
                    Text(verbatim: summary)
                }
            }
            // A menu leaves the icon of a toggle out unless told otherwise, and only draws one
            // that comes as a Label's: a bare Image beside the texts reaches the menu item and
            // is not shown (macOS 27.2).
            .labelStyle(.titleAndIcon)
            // A menu draws an item's icon in the tint, which here is the island's color. The
            // symbols are the bar's, and should be as plain in the menu as they are there.
            .tint(.primary)
            // A menu item is one line. Whatever the summary left out is a hover away.
            .help(choice.description ?? "")
        }
    }
}

/// How full the agent's context window is.
struct ContextUsageRing: View {
    let usage: UsageUpdate

    private var fraction: Double {
        usage.size > 0 ? min(Double(usage.used) / Double(usage.size), 1) : 0
    }

    var body: some View {
        ProgressRing(fraction: fraction)
            .frame(width: 14, height: 14)
            .frame(width: 20, height: 20)
            .contentShape(.rect)
            .help(summary)
            .accessibilityElement()
            .accessibilityLabel("Context")
            .accessibilityValue(summary)
            .accessibilityIdentifier("chat.usage")
    }

    private var summary: String {
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        let used = usage.used.formatted(.number.notation(.compactName))
        let size = usage.size.formatted(.number.notation(.compactName))
        return "\(percent) of context used (\(used) of \(size) tokens)"
    }
}

#if DEBUG
/// Claude's settings, the most any agent offers so far.
private let previewControls: [ChatControl] = {
    func select(_ id: String, _ name: String, _ category: ConfigOptionCategory?, _ choices: [String], current: Int = 0) -> ChatControl {
        let values = choices.map { ConfigOptionValue(value: $0.lowercased(), name: $0) }
        return ChatControl(
            id: id, name: name, description: name, category: category,
            value: .select(current: values[current].value, groups: [.init(name: nil, choices: values)])
        )
    }
    return [
        select("mode", "Mode", .mode, ["Manual", "Accept edits", "Plan", "Auto"], current: 3),
        select("model", "Model", .model, ["Default (recommended)", "Opus 5.5", "Fable 5.2", "Sonnet 5.5"]),
        select("effort", "Effort", .thoughtLevel, ["Default", "Low", "Medium", "High"], current: 2),
        select("ultracode", "Ultracode", .modelConfig, ["On", "Off"], current: 1),
        select("fast", "Fast mode", nil, ["Off", "On"], current: 1),
        select("agent", "Agent", nil, ["Default", "Reviewer"]),
    ]
}()

#Preview("Controls Bar") {
    @MainActor func bar(_ controls: [ChatControl]) -> some View {
        ChatControlsBar(controls: controls, select: { _, _ in }, setToggle: { _, _ in })
    }
    func mode(_ value: String, _ name: String) -> ChatControl {
        ChatControl(
            id: "mode", name: "Mode", category: .mode,
            value: .select(current: value, groups: [.init(name: nil, choices: [ConfigOptionValue(value: value, name: name)])])
        )
    }
    return VStack(alignment: .leading, spacing: 16) {
        bar(previewControls)
        bar([mode("plan", "Plan")] + previewControls.dropFirst())
        bar([mode("agent-full-access", "Full access")] + previewControls.dropFirst())
        // Nothing but a mode and a model, then with one more setting that is not the effort.
        bar(Array(previewControls.prefix(2)))
        bar(Array(previewControls.prefix(2)) + [previewControls[5]])
        bar(previewControls)
            .frame(width: 120, alignment: .leading)
    }
    .padding(20)
    .frame(width: 520, alignment: .leading)
}

#Preview("Controls Popover") {
    ControlsPopover(controls: previewControls.filter { !$0.isPrimary }, select: { _, _ in }, setToggle: { _, _ in })
}
#endif
