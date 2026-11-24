import ACPKit
import SwiftUI

/// The agent's settings under the composer's text: mode, model and whatever else it offers, each
/// a quiet menu showing the current choice.
struct ChatControlsBar: View {
    let controls: [ChatControl]
    let select: @MainActor (_ controlID: String, _ value: String) -> Void
    let setToggle: @MainActor (_ controlID: String, _ isOn: Bool) -> Void

    var body: some View {
        // Claude offers six settings. As many as fit are shown, mode and model first; the rest
        // move into one menu instead of being squeezed or cut off.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: controls.count, through: 0, by: -1)), id: \.self) { shown in
                row(showing: shown)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func row(showing count: Int) -> some View {
        HStack(spacing: 12) {
            ForEach(controls.prefix(count)) { control in
                ControlButton(control: control, select: select, setToggle: setToggle)
            }
            if count < controls.count {
                Menu {
                    ForEach(controls.dropFirst(count)) { control in
                        switch control.value {
                        case let .select(current, groups):
                            Menu(control.name) {
                                ControlChoices(controlID: control.id, current: current, groups: groups, select: select)
                            }
                        case let .toggle(isOn):
                            Toggle(control.name, isOn: Binding(get: { isOn }, set: { setToggle(control.id, $0) }))
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(height: 20)
                        .contentShape(.rect)
                }
                .quietMenu()
                .help("More Settings")
                .accessibilityLabel("More Settings")
                .accessibilityIdentifier("chat.control.more")
            }
        }
    }
}

private struct ControlButton: View {
    let control: ChatControl
    let select: @MainActor (String, String) -> Void
    let setToggle: @MainActor (String, Bool) -> Void

    var body: some View {
        switch control.value {
        case let .select(current, groups):
            Menu {
                ControlChoices(controlID: control.id, current: current, groups: groups, select: select)
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: control.barLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 20)
                .contentShape(.rect)
            }
            .quietMenu()
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
                    .frame(height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(control.description ?? control.name)
            .accessibilityLabel(control.name)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier("chat.control.\(control.id)")
        }
    }
}

extension ChatControl {
    /// What the control's button says. The mode and the model are understood from the value
    /// alone; "Off" or "Default" next to six other settings is not, so those carry their name,
    /// unless the value already does ("Extended Thinking" for a control named "Thinking").
    var barLabel: String {
        switch value {
        case let .toggle(isOn):
            return "\(name): \(isOn ? "On" : "Off")"
        case .select:
            guard let choice = currentChoiceName else { return name }
            if category == .mode || category == .model { return choice }
            if choice.localizedStandardContains(name) { return choice }
            return "\(name): \(choice)"
        }
    }
}

/// The choices of one setting as menu items, the current one checked. A menu scrolls by itself,
/// which a list of 55 models needs.
private struct ControlChoices: View {
    let controlID: String
    let current: String?
    let groups: [ChatControl.ChoiceGroup]
    let select: @MainActor (String, String) -> Void

    var body: some View {
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
                set: { if $0 { select(controlID, choice.value) } }
            )) {
                Text(verbatim: choice.name)
                if let description = choice.description, !description.isEmpty {
                    Text(verbatim: description)
                }
            }
        }
    }
}

private extension View {
    /// A menu that is only its label: no border, no indicator, no wider than it needs.
    func quietMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
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
