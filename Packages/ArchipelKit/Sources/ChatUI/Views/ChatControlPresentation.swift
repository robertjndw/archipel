import ACPKit
import Foundation

extension ChatControl {
    /// The mode and the model are changed most often, so the bar always shows them.
    var isPrimary: Bool { category == .mode || category == .model }

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

    /// Whether a switch is on. Nil for a setting that is not a switch.
    var isSwitchedOn: Bool? {
        switch value {
        case let .toggle(isOn): isOn
        case let .select(current, _): switchValues.map { current == $0.on }
        }
    }

    /// What is switched on among `controls`, as the settings button tells it: "Fast mode on",
    /// "Fast mode and Ultracode on". Nil when nothing is.
    ///
    /// Every switch that is on counts. An agent does not say what a setting's default is, so one
    /// that starts out on cannot be told from one the user turned on.
    static func switchSummary(of controls: [ChatControl]) -> String? {
        let names = controls.filter { $0.isSwitchedOn == true }.map(\.name)
        guard !names.isEmpty else { return nil }
        // The sentence around the list is English, so the list is too, whatever the Mac's language.
        return "\(names.formatted(.list(type: .and).locale(Locale(identifier: "en_US")))) on"
    }

    /// The choices of a setting that is a scale from little to much, in the agent's order.
    struct LevelScale: Equatable {
        var levels: [ConfigOptionValue]
        /// Claude's "Default": leaves the level to the agent, so it is not one of the levels.
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
    /// cannot be known. What can: the model in use, the ones the user starred (`favorites`, in
    /// the agent's order as everywhere else), the ones chosen before (`recent`, latest first),
    /// then the rest of the provider in use ("anthropic/…" in OpenCode), then whatever the agent
    /// lists first, which Claude and Codex order by recommendation.
    func modelShortlist(favorites: [String] = [], recent: [String], limit: Int = 5) -> ModelShortlist? {
        guard category == .model, case let .select(current, groups) = value else { return nil }
        let choices = groups.flatMap(\.choices)
        // Moving two or three models into a submenu saves nothing.
        guard choices.count >= limit + 4 else { return nil }
        let known = Set(choices.map(\.value))
        let provider = current.flatMap(Self.provider)
        let sameProvider = provider == nil ? [] : choices.map(\.value).filter { Self.provider(of: $0) == provider }
        var picked: [String] = []
        let starred = choices.map(\.value).filter(favorites.contains)
        for value in [current].compactMap(\.self) + starred + recent + sameProvider + choices.map(\.value)
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
    static func provider(of value: String) -> String? {
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

    /// What the control's menu in the settings popover says: the current choice, a model without
    /// its provider as the model list shows it, and anything longer than `limit` cut in its
    /// middle, where a model's name says least. The popover is as wide as its widest value.
    func popoverLabel(limit: Int) -> String {
        guard case let .select(current?, groups) = value,
              let choice = groups.lazy.flatMap(\.choices).first(where: { $0.value == current })
        else { return "" }
        let name = category == .model ? ModelSearch.title(of: choice, provider: Self.provider(of: choice.value)) : choice.name
        guard limit >= 3, name.count > limit else { return name }
        let kept = limit - 1
        return name.prefix((kept + 1) / 2).trimmingCharacters(in: .whitespaces) + "…" + name.suffix(kept / 2).trimmingCharacters(in: .whitespaces)
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

    /// The current model's name, for places with no room for the menu. Nil while it's a bare
    /// "Default" we can't resolve, since that says nothing about which model runs.
    var resolvedModelName: String? {
        guard category == .model, case let .select(current?, _) = value, let choice = currentChoiceName else { return nil }
        if let model = defaultModelName { return model }
        return current.caseInsensitiveCompare("default") == .orderedSame ? nil : choice
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

    /// One place the slider's thumb can rest.
    struct Stop: Equatable {
        var name: String
        /// What choosing the stop sends. Nil for a default the agent reports without offering it
        /// as a choice (OpenCode): the thumb can leave that stop but not come back to it.
        var value: String?
        var isDefault = false
    }

    /// Whether the agent decides the level itself right now: its "Default" is chosen, or it
    /// reports a value that is none of its levels.
    func isAtDefault(_ control: ChatControl) -> Bool {
        fraction(of: control) == nil
    }

    /// The slider's stops: the levels, and before them one for the default when the agent offers
    /// one or `includingDefault` asks for it.
    ///
    /// No agent says which level its default is, so the default is not marked on one of them:
    /// it has a stop of its own in front of the lowest, which claims nothing about how hard the
    /// agent then thinks.
    func stops(includingDefault: Bool) -> [Stop] {
        let levels = levels.map { Stop(name: $0.name, value: $0.value) }
        guard includingDefault || fallback != nil else { return levels }
        return [Stop(name: fallback?.name ?? "Default", value: fallback?.value, isDefault: true)] + levels
    }

    /// The stop the control is at. Anything that is not a level is at the default's, the first.
    func stopIndex(of control: ChatControl, in stops: [Stop]) -> Int {
        guard case let .select(current?, _) = control.value,
              let index = stops.firstIndex(where: { !$0.isDefault && $0.value == current })
        else { return 0 }
        return index
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
