import ACPKit
import SwiftUI
import UISupport

/// The agent's settings under the composer's text. The mode, with a symbol of its own, and the
/// model are quiet menus showing the current choice; a model list too long for a menu opens a
/// list to search instead. Whatever else the agent offers sits behind one button, which shows
/// the thinking effort as a gauge when there is one.
struct ChatControlsBar: View {
    let controls: [ChatControl]
    /// The models the user chose before with this agent, latest first. They stay at hand when
    /// the agent's list is too long to show whole.
    var recentModels: [String] = []
    /// The models the user starred with this agent.
    var favoriteModels: [String] = []
    /// Returns once the agent has answered, so a control can show the choice as made until then.
    let select: @MainActor (_ controlID: String, _ value: String) async -> Void
    let setToggle: @MainActor (_ controlID: String, _ isOn: Bool) -> Void

    @State private var showsSettings = false
    /// How many of `inline` the row that fits is showing. The rest is in the popover.
    @State private var shownCount: Int?
    /// Where the settings button is in the bar right now.
    @State private var settingsFrame = CGRect.zero
    /// Where it was when the popover opened. The button gets wider and narrower with the level
    /// it names, and a popover that followed it would slide sideways under a slider being
    /// dragged, which changes the level again.
    @State private var popoverAnchor = CGRect.zero

    private nonisolated static let space = "chat.controls"

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
        let hidden = rest(after: inline.prefix(min(shownCount ?? inline.count, inline.count)))
        // A narrow pane shows fewer, the mode last to go; what does not fit moves behind the
        // settings button instead of being squeezed or cut off.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: inline.count, through: 0, by: -1)), id: \.self) { shown in
                row(inline.prefix(shown))
                    .onAppear { shownCount = shown }
            }
        }
        .coordinateSpace(.named(Self.space))
        // On the bar and not on the button: each row above is a view of its own, and a popover
        // on one row's button closes when a longer label makes the bar change rows, which is
        // what moving the effort slider inside that popover does.
        .popover(isPresented: $showsSettings, attachmentAnchor: .rect(.rect(popoverAnchor)), arrowEdge: .top) {
            ControlsPopover(controls: hidden, recentModels: recentModels, favoriteModels: favoriteModels, select: select, setToggle: setToggle)
        }
        .onChange(of: hidden.isEmpty) {
            // The row that fits now has no settings button for the popover to belong to.
            if hidden.isEmpty { showsSettings = false }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        // Each item has room around its label for the hover highlight. Taking that room back at
        // the leading edge keeps the first label in line with the text above.
        .padding(.leading, -BarItem.inset)
    }

    /// The settings a row showing `shown` leaves to the popover.
    private func rest(after shown: ArraySlice<ChatControl>) -> [ChatControl] {
        controls.filter { control in !shown.contains { $0.id == control.id } }
    }

    private func row(_ shown: ArraySlice<ChatControl>) -> some View {
        let rest = rest(after: shown)
        return HStack(spacing: 0) {
            ForEach(shown) { control in
                ControlButton(control: control, recentModels: recentModels, favoriteModels: favoriteModels, select: select, setToggle: setToggle)
            }
            if !rest.isEmpty {
                let effort = rest.first { $0.levelScale != nil }
                // A switch in the popover is out of sight, so the button says when one is on.
                let switchedOn = ChatControl.switchSummary(of: rest)
                Button {
                    popoverAnchor = settingsFrame
                    showsSettings.toggle()
                } label: {
                    SettingsLabel(effort: effort, marksSwitch: switchedOn != nil)
                        .barItemLabel()
                }
                .buttonStyle(.plain)
                .barItem(isActive: showsSettings)
                .help(switchedOn.map { "More Settings: \($0)" } ?? "More Settings")
                .accessibilityLabel("More Settings")
                .accessibilityValue([effort?.barLabel, switchedOn].compactMap(\.self).joined(separator: ", "))
                .accessibilityIdentifier("chat.control.more")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { settingsFrame = $0 }
            }
        }
    }
}

/// The settings button. With a thinking effort among the settings it is a gauge at that level
/// and the level's name, so the effort can be read without opening the popover. A dot in the
/// island's color on its symbol says that a switch in the popover is on.
private struct SettingsLabel: View {
    let effort: ChatControl?
    let marksSwitch: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let effort, let scale = effort.levelScale {
            let fraction = scale.fraction(of: effort)
            HStack(spacing: 4) {
                Image(systemName: ChatControl.LevelScale.gaugeSymbol(for: fraction))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .overlay(alignment: .topTrailing) { dot }
                Text(verbatim: effort.currentChoiceName ?? scale.fallback?.name ?? effort.name)
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .interpolate)
            }
            .animation(reduceMotion ? nil : Motion.hover, value: fraction)
            .animation(reduceMotion ? nil : Motion.hover, value: marksSwitch)
        } else {
            Image(systemName: "slider.horizontal.3")
                .overlay(alignment: .topTrailing) { dot }
                .animation(reduceMotion ? nil : Motion.hover, value: marksSwitch)
        }
    }

    @ViewBuilder private var dot: some View {
        if marksSwitch {
            Circle()
                .fill(.tint)
                .frame(width: 5, height: 5)
                // Half out of the symbol's corner, like a badge, so it covers none of the gauge.
                .offset(x: 2.5, y: -1.5)
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                .accessibilityHidden(true)
        }
    }
}

/// The padding around a bar item's label. Put this on the label, not the button: a plain button
/// only takes clicks on its label, so padding outside it gets the hover highlight but no clicks.
struct BarItemLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, BarItem.inset)
            .frame(height: 24)
            .contentShape(.rect)
    }
}

/// The highlight a bar item shows on hover or while its menu or popover is open, like a toolbar
/// item's. Pair it with `barItemLabel()` on the button's label.
struct BarItem: ViewModifier {
    static let inset: CGFloat = 6

    var isActive = false

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
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

    func barItemLabel() -> some View {
        modifier(BarItemLabel())
    }
}

/// The settings that are not in the bar, one row each: the name, then a switch or a menu of the
/// choices. It stays open, so several can be changed in one visit.
struct ControlsPopover: View {
    let controls: [ChatControl]
    var recentModels: [String] = []
    var favoriteModels: [String] = []
    let select: @MainActor (String, String) async -> Void
    let setToggle: @MainActor (String, Bool) -> Void

    /// As wide as the effort slider is comfortable to drag. Names and values that need more make
    /// the popover wider; they are never squeezed into what the slider left.
    static let minimumWidth: CGFloat = 240
    /// A value longer than this is cut in its middle. A model's name has no upper bound.
    static let valueLimit = 28

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            ForEach(controls) { control in
                GridRow {
                    if let scale = control.levelScale {
                        LevelSlider(control: control, scale: scale, select: select)
                            // Its ideal width is stated, since a slider left to itself takes all
                            // the room a popover may have.
                            .frame(minWidth: Self.minimumWidth, idealWidth: Self.minimumWidth, maxWidth: .infinity)
                            .gridCellColumns(2)
                    } else {
                        // The help is on the name and the field, never around a slider: there
                        // it replaces the slider's role for VoiceOver.
                        Text(verbatim: control.name)
                            .lineLimit(1)
                            .fixedSize()
                            .help(control.description ?? "")
                        field(for: control)
                            .gridColumnAlignment(.trailing)
                            .help(control.description ?? "")
                            .accessibilityLabel(control.name)
                            .accessibilityIdentifier("chat.control.\(control.id)")
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(16)
        // The popover hangs on the bar and would take the bar's gray along.
        .foregroundStyle(.primary)
    }

    @ViewBuilder private func field(for control: ChatControl) -> some View {
        switch control.value {
        case let .toggle(isOn):
            switchToggle(control.name, isOn: isOn) { setToggle(control.id, $0) }
        case let .select(current, _):
            if let values = control.switchValues {
                // Claude sends its on/off settings as a choice between "On" and "Off".
                switchToggle(control.name, isOn: current == values.on) { isOn in
                    Task { await select(control.id, isOn ? values.on : values.off) }
                }
            } else {
                Menu(control.popoverLabel(limit: Self.valueLimit)) {
                    ControlChoices(control: control, recentModels: recentModels, favoriteModels: favoriteModels, select: select)
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
    var favoriteModels: [String] = []
    let select: @MainActor (String, String) async -> Void
    let setToggle: @MainActor (String, Bool) -> Void

    var body: some View {
        switch control.value {
        case .select:
            if control.needsModelSearch {
                ModelSearchButton(control: control, recentModels: recentModels, select: select)
            } else {
                // Shift-Tab moves the mode on from the composer, which nothing here shows. The
                // tooltip and the menu's last row say so, and a tip does once it is due.
                let isCyclable = control.category == .mode && control.nextChoice != nil
                Menu {
                    ControlChoices(control: control, recentModels: recentModels, favoriteModels: favoriteModels, select: select)
                } label: {
                    ChoiceLabel(control: control)
                        .barItemLabel()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .barItem()
                .modeShortcutTip(isCyclable: isCyclable)
                .help((control.description ?? control.name) + (isCyclable ? " (⇧⇥)" : ""))
                .accessibilityLabel(control.name)
                .accessibilityValue(control.currentChoiceName ?? "")
                .accessibilityIdentifier("chat.control.\(control.id)")
            }
        case let .toggle(isOn):
            Button {
                setToggle(control.id, !isOn)
            } label: {
                Text(verbatim: control.barLabel)
                    .lineLimit(1)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .barItemLabel()
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

/// What the item of a setting with choices shows in the bar: the mode's symbol, the current
/// choice and a chevron.
private struct ChoiceLabel: View {
    let control: ChatControl

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mode = control.currentModeStyle
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
        .animation(reduceMotion ? nil : Motion.hover, value: control.barLabel)
    }
}

/// The model item of a list long enough to search. A menu cannot hold a search field, so this
/// one opens a popover, and looks and reads like the menus beside it until it does.
private struct ModelSearchButton: View {
    let control: ChatControl
    let recentModels: [String]
    let select: @MainActor (String, String) async -> Void

    @State private var isOpen = false
    @Environment(\.chatAgentName) private var agentName

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            ChoiceLabel(control: control)
                .barItemLabel()
        }
        .buttonStyle(.plain)
        .barItem(isActive: isOpen)
        .help(control.description ?? control.name)
        .accessibilityLabel(control.name)
        .accessibilityValue(control.currentChoiceName ?? "")
        .accessibilityIdentifier("chat.control.\(control.id)")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            ModelPicker(control: control, recentModels: recentModels, agentName: agentName) { value in
                isOpen = false
                // Choosing the model in use again only closes the list.
                if control.currentValue != value { Task { await select(control.id, value) } }
            }
        }
    }
}

/// The choices of one setting as menu items, the current one checked. A menu scrolls by itself,
/// but nobody reads 55 models to find the one they use. In the bar such a list has its search
/// popover; here, for the settings popover a narrow pane moves the model into, it shows a
/// handful and keeps the rest one level down.
private struct ControlChoices: View {
    let control: ChatControl
    var recentModels: [String] = []
    var favoriteModels: [String] = []
    let select: @MainActor (String, String) async -> Void

    var body: some View {
        if let shortlist = control.modelShortlist(favorites: favoriteModels, recent: recentModels) {
            Section { items(shortlist.shown) }
            Menu("Other Models") { sections(shortlist.others) }
        } else if case let .select(_, groups) = control.value {
            sections(groups)
            if control.category == .mode, control.nextChoice != nil {
                // A row to read, not a command. An item with a real keyboard shortcut would show
                // the keys the same way, but then the menu's button answers Shift-Tab itself
                // whenever the composer is not the one asked first.
                Section {
                    Button("Switch Modes with ⇧⇥") {}
                        .disabled(true)
                        .accessibilityLabel("Switch modes with Shift-Tab")
                        .accessibilityIdentifier("chat.control.modeShortcut")
                }
            }
        }
    }

    private var choices: [ConfigOptionValue] {
        guard case let .select(_, groups) = control.value else { return [] }
        return groups.flatMap(\.choices)
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
        let allChoices = self.choices
        return ForEach(choices, id: \.value) { choice in
            Toggle(isOn: Binding(
                get: { choice.value == control.currentValue },
                // Choosing the checked item again turns the toggle "off"; there is nothing to do.
                set: { isOn in
                    guard isOn else { return }
                    if control.category == .mode { ChatTips.modeChosenFromMenu() }
                    Task { await select(control.id, choice.value) }
                }
            )) {
                if control.category == .mode {
                    // The same symbol the bar shows for the mode once it is chosen.
                    Label {
                        Text(verbatim: choice.name)
                    } icon: {
                        Image(systemName: ChatControl.modeStyle(for: choice, among: allChoices).symbol)
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
    let unknownModes = ChatControl(
        id: "mode", name: "Mode", category: .mode,
        value: .select(current: "oracle", groups: [.init(name: nil, choices: ["Sisyphus", "Oracle", "Librarian"].map {
            ConfigOptionValue(value: $0.lowercased(), name: $0)
        })])
    )
    let manyModels = ChatControl(
        id: "model", name: "Model", category: .model,
        value: .select(current: "anthropic/model-3", groups: [.init(name: nil, choices: (1...24).map {
            let provider = ["anthropic", "openai", "local"][$0 % 3]
            return ConfigOptionValue(value: "\(provider)/model-\($0)", name: "\(provider)/Model \($0)")
        })])
    )
    return VStack(alignment: .leading, spacing: 16) {
        bar(previewControls)
        bar([mode("plan", "Plan")] + previewControls.dropFirst())
        bar([mode("agent-full-access", "Full access")] + previewControls.dropFirst())
        // Nothing but a mode and a model, then with one more setting that is not the effort.
        bar(Array(previewControls.prefix(2)))
        bar(Array(previewControls.prefix(2)) + [previewControls[5]])
        // Modes no word places, and a model list long enough to open the search.
        bar([unknownModes, manyModels] + previewControls.dropFirst(2))
        bar(previewControls)
            .frame(width: 120, alignment: .leading)
    }
    .padding(20)
    .frame(width: 520, alignment: .leading)
}

#Preview("Controls Popover") {
    ControlsPopover(controls: previewControls.filter { !$0.isPrimary }, select: { _, _ in }, setToggle: { _, _ in })
}

#Preview("Controls Popover, Narrow Pane") {
    // What a pane too narrow for the bar's items moves into the popover, with a model whose
    // name is long enough to be cut.
    let model = ChatControl(
        id: "model", name: "Model", category: .model,
        value: .select(current: "anthropic/fable", groups: [.init(name: nil, choices: [
            ConfigOptionValue(value: "anthropic/fable", name: "anthropic/Claude Fable 5.2 with extended thinking (preview)"),
            ConfigOptionValue(value: "anthropic/opus", name: "anthropic/Claude Opus 5.5"),
        ])])
    )
    return ControlsPopover(controls: [previewControls[0], model] + previewControls.dropFirst(2), select: { _, _ in }, setToggle: { _, _ in })
}
#endif
