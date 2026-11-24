import ACPKit
import Foundation

/// A long model list as the search popover shows it: sections of rows, filtered by what is typed.
enum ModelSearch {
    /// From this many models on the bar opens the search popover; below it a menu shows them all
    /// at a glance. It is the count from which the menu starts to hide models in "Other Models":
    /// a list long enough to need a second level is long enough to need a search.
    static let threshold = 9

    /// How many of the recent models get a row of their own on top.
    static let recentLimit = 5

    struct Row: Equatable, Identifiable {
        /// Unique in the whole list. A favorite shows a second time under its provider.
        var id: String
        var choice: ConfigOptionValue
        /// The name without the provider, which the section's title or `detail` says.
        var title: String
        /// The provider, in the sections that mix them.
        var detail: String?
    }

    struct Section: Equatable, Identifiable {
        var id: String
        var title: String?
        var rows: [Row]
    }

    /// The models by provider. Agents that group their models keep their groups; OpenCode sends
    /// one flat list of "provider/model", which is split by that provider.
    static func providerGroups(of groups: [ChatControl.ChoiceGroup]) -> [ChatControl.ChoiceGroup] {
        guard groups.count == 1, groups[0].name == nil else { return groups }
        var names: [String?] = []
        var choices: [String?: [ConfigOptionValue]] = [:]
        for choice in groups[0].choices {
            let provider = ChatControl.provider(of: choice.value)
            if choices[provider] == nil { names.append(provider) }
            choices[provider, default: []].append(choice)
        }
        return names.map { ChatControl.ChoiceGroup(name: $0, choices: choices[$0] ?? []) }
    }

    /// What the popover lists. With nothing typed: the favorites, the models chosen before
    /// (`recent`, latest first), then every model under its provider. A query leaves only the
    /// providers' sections, each cut down to its matches, so no model shows twice in a result.
    static func sections(of control: ChatControl, query: String, favorites: [String], recent: [String]) -> [Section] {
        guard case let .select(_, agentGroups) = control.value else { return [] }
        let groups = providerGroups(of: agentGroups)
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)

        var sections: [Section] = []
        if terms.isEmpty {
            let all = groups.flatMap { group in group.choices.map { (choice: $0, provider: group.name) } }
            func rows(_ values: [String], section: String) -> [Row] {
                var seen = Set<String>()
                return values.compactMap { value in
                    guard seen.insert(value).inserted, let found = all.first(where: { $0.choice.value == value }) else { return nil }
                    return Row(
                        id: "\(section)/\(value)", choice: found.choice,
                        title: title(of: found.choice, provider: found.provider), detail: found.provider
                    )
                }
            }
            // In the agent's order, so a favorite keeps its place when another is added.
            let starred = rows(all.map { $0.choice.value }.filter(favorites.contains), section: "favorites")
            if !starred.isEmpty { sections.append(Section(id: "favorites", title: "Favorites", rows: starred)) }
            let recents = rows(Array(recent.filter { !favorites.contains($0) }), section: "recent").prefix(recentLimit)
            if !recents.isEmpty { sections.append(Section(id: "recent", title: "Recent", rows: Array(recents))) }
        }
        for (index, group) in groups.enumerated() {
            var seen = Set<String>()
            let rows = group.choices.compactMap { choice -> Row? in
                guard matches(choice, provider: group.name, terms: terms), seen.insert(choice.value).inserted else { return nil }
                return Row(id: "provider\(index)/\(choice.value)", choice: choice, title: title(of: choice, provider: group.name))
            }
            if !rows.isEmpty { sections.append(Section(id: "provider\(index)", title: group.name, rows: rows)) }
        }
        return sections
    }

    /// Every typed word has to be somewhere in the model's name, its id or its provider, so
    /// "son 5" finds "Claude Sonnet 5" and "anthropic" everything of that provider.
    static func matches(_ choice: ConfigOptionValue, provider: String?, terms: [String]) -> Bool {
        terms.allSatisfy { term in
            [choice.name, choice.value, provider ?? ""].contains {
                $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// "Claude Fable 5" of "anthropic/Claude Fable 5" under "anthropic".
    static func title(of choice: ConfigOptionValue, provider: String?) -> String {
        guard let provider, choice.name.count > provider.count + 1,
              choice.name.range(of: provider + "/", options: [.caseInsensitive, .anchored]) != nil
        else { return choice.name }
        return String(choice.name.dropFirst(provider.count + 1))
    }

    /// The row the keyboard starts on: the model in use when it is listed, else the first.
    static func initialSelection(in sections: [Section], current: String?) -> Int {
        sections.flatMap(\.rows).firstIndex { $0.choice.value == current } ?? 0
    }
}

extension ChatControl {
    /// A model list too long for a menu, which the bar shows in the search popover instead.
    var needsModelSearch: Bool {
        guard category == .model, case let .select(_, groups) = value else { return false }
        return groups.reduce(0) { $0 + $1.choices.count } >= ModelSearch.threshold
    }
}
