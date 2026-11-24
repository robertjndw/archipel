import ACPKit
import AppKit
@testable import ChatUI
import Foundation
import SwiftUI
import Testing

@Suite
struct ModeStyleTests {
    private func mode(_ value: String, _ name: String, _ description: String? = nil) -> ConfigOptionValue {
        ConfigOptionValue(value: value, name: name, description: description)
    }

    // The modes of the three agents, as their session/new fixtures in ACPKitTests have them.
    private var claude: [ConfigOptionValue] {
        [
            mode("default", "Manual", "Always ask before making changes"),
            mode("acceptEdits", "Accept edits", "Automatically accept all file edits"),
            mode("plan", "Plan", "Create a plan before making changes"),
            mode("auto", "Auto", "Claude handles permission decisions"),
        ]
    }

    private var codex: [ConfigOptionValue] {
        [
            mode("read-only", "Read-only", "Requires approval to edit files and access the internet."),
            mode("workspace-write", "Workspace access", "Edit workspace files; ask before writing outside the workspace or accessing the network."),
            mode("agent", "Auto review", "Only ask for actions detected as potentially unsafe"),
            mode("agent-full-access", "Full access", "Unrestricted access to the internet and any file on your computer"),
        ]
    }

    private var openCode: [ConfigOptionValue] {
        [
            mode("build", "Build", "The default agent. Executes tools based on configured permissions."),
            mode("plan", "Plan", "Read-only agent for exploring the codebase and planning work before implementation."),
        ]
    }

    private func symbols(_ modes: [ConfigOptionValue]) -> [String] {
        modes.map { ChatControl.modeStyle(for: $0, among: modes).symbol }
    }

    @Test func theAgentsOwnModesEachHaveTheirSymbol() {
        #expect(symbols(claude) == ["hand.raised", "pencil", "list.clipboard", "sparkles"])
        #expect(symbols(codex) == ["eye", "pencil", "sparkles", "exclamationmark.shield"])
        #expect(symbols(openCode) == ["hammer", "list.clipboard"])
    }

    @Test func onlyAModeThatTakesTheLimitsAwayIsMarked() {
        let all = claude + codex + openCode
        #expect(all.filter { ChatControl.modeStyle(for: $0, among: all).isUnrestricted }.map(\.value) == ["agent-full-access"])
        #expect(ChatControl.modeStyle(for: mode("bypassPermissions", "Bypass permissions")).isUnrestricted)
        #expect(ChatControl.modeStyle(for: mode("yolo", "YOLO")).isUnrestricted)
        // Refusing instead of asking is the opposite of full access.
        let dontAsk = ChatControl.modeStyle(for: mode("dontAsk", "Don't ask"))
        #expect(dontAsk == ChatControl.ModeStyle(symbol: "hand.raised.slash"))
    }

    @Test func idsAreReadAsTheirWords() {
        #expect(ModeWords.words(in: "acceptEdits") == ["accept", "edits"])
        #expect(ModeWords.words(in: "agent-full-access Full access") == ["agent", "full", "access", "full", "access"])
        #expect(ModeWords.words(in: "Don’t ask") == ["dont", "ask"])
        #expect(ModeWords.words(in: "smart_approve YOLO") == ["smart", "approve", "yolo"])
    }

    @Test func aWordIsNotFoundInsideAnother() {
        // "task" has "ask" in it, "thread" has "read" and "explanation" has "plan".
        #expect(ModeWords.style(for: mode("tasks", "Task Thread Explanation")) == nil)
        // The longer forms of a word are still the word.
        #expect(ChatControl.modeStyle(for: mode("p", "Planning")).symbol == "list.clipboard")
        #expect(ChatControl.modeStyle(for: mode("e", "Editing")).symbol == "pencil")
    }

    @Test func aPhraseSaysMoreThanItsWords() {
        // An editing mode by its words, the manual one by what it says.
        #expect(ChatControl.modeStyle(for: mode("ask", "Ask before edits")).symbol == "hand.raised")
        #expect(ChatControl.modeStyle(for: mode("autoEdit", "Auto Edit")).symbol == "pencil")
        #expect(ChatControl.modeStyle(for: mode("ask", "Ask")).symbol == "bubble.left")
        #expect(ChatControl.modeStyle(for: mode("smart_approve", "Smart approve")).symbol == "sparkles")
        #expect(ChatControl.modeStyle(for: mode("approve", "Approve")).symbol == "hand.raised")
        #expect(ChatControl.modeStyle(for: mode("architect", "Architect")).symbol == "list.clipboard")
        #expect(ChatControl.modeStyle(for: mode("debug", "Debug")).symbol == "ladybug")
    }

    @Test func theDescriptionPlacesAModeItsNameDoesNot() {
        #expect(ChatControl.modeStyle(for: mode("m1", "Careful", "Always asks before making changes")).symbol == "hand.raised")
        #expect(ChatControl.modeStyle(for: mode("m2", "Sketch", "Plans the work before any change is made")).symbol == "list.clipboard")
        #expect(ChatControl.modeStyle(for: mode("m3", "Observer", "A read-only look at the project")).symbol == "eye")
        let turbo = ChatControl.modeStyle(for: mode("m4", "Turbo", "Runs every command without asking"))
        #expect(turbo == ChatControl.ModeStyle(symbol: "exclamationmark.shield", isUnrestricted: true))
        // The name comes first: what Codex says about its read-only mode mentions editing.
        #expect(ChatControl.modeStyle(for: codex[0], among: codex).symbol == "eye")
        // Prose uses "default", "edit" and "auto" for anything, so they place nothing there.
        #expect(ModeWords.style(for: mode("m5", "Sisyphus", "The default agent. Automatically edits what it must.")) == nil)
    }

    @Test func unknownModesAreToldApartByTheirInitial() {
        let modes = [mode("a", "Sisyphus"), mode("b", "Oracle"), mode("c", "Librarian"), mode("plan", "Plan")]
        #expect(symbols(modes) == ["s.circle", "o.circle", "l.circle", "list.clipboard"])
        #expect(ChatControl.modeStyle(for: mode("x", "Émile")).symbol == "e.circle")
    }

    @Test func aSharedInitialGivesWayToThePlaceInTheList() {
        let modes = [mode("a", "Sisyphus"), mode("b", "Scribe"), mode("c", "Oracle"), mode("d", "作家")]
        #expect(symbols(modes) == ["1.circle", "2.circle", "o.circle", "4.circle"])
        // A known mode with the same initial does not take the letter away.
        let mixed = [mode("plan", "Plan"), mode("p", "Prometheus")]
        #expect(symbols(mixed) == ["list.clipboard", "p.circle"])
    }

    @Test func withNothingToGoOnTheSymbolIsNeutral() {
        #expect(ChatControl.modeStyle(for: mode("x", "42")).symbol == "switch.2")
        let many = (1...60).map { mode("m\($0)", "\($0)") }
        #expect(ChatControl.modeStyle(for: many[49], among: many).symbol == "50.circle")
        #expect(ChatControl.modeStyle(for: many[50], among: many).symbol == "switch.2")
    }

    @Test func everySymbolExists() {
        let fallbacks = "abcdefghijklmnopqrstuvwxyz".map { "\($0).circle" } + (1...50).map { "\($0).circle" } + ["switch.2"]
        for symbol in ModeWords.symbols + fallbacks {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) is not an SF Symbol")
        }
    }

    @Test func theBarShowsTheCurrentModesSymbol() {
        let control = ChatControl(
            id: "mode", name: "Mode", category: .mode,
            value: .select(current: "b", groups: [.init(name: nil, choices: [mode("a", "Sisyphus"), mode("b", "Scribe")])])
        )
        #expect(control.currentModeStyle?.symbol == "2.circle")
    }
}

@Suite
struct HiddenSettingsTests {
    private func onOff(_ name: String, isOn: Bool, values: [String] = ["off", "on"]) -> ChatControl {
        ChatControl(
            id: name, name: name, category: nil,
            value: .select(
                current: values.first { ($0.lowercased() == "on") == isOn },
                groups: [.init(name: nil, choices: values.map { ConfigOptionValue(value: $0, name: $0.capitalized) })]
            )
        )
    }

    private let effort = ChatControl(
        id: "effort", name: "Effort", category: .thoughtLevel,
        value: .select(current: "on", groups: [.init(name: nil, choices: ["low", "on", "high"].map { ConfigOptionValue(value: $0, name: $0) })])
    )

    @Test func aSwitchIsOnWhateverShapeItComesIn() {
        #expect(onOff("Fast mode", isOn: true).isSwitchedOn == true)
        #expect(onOff("Fast mode", isOn: false).isSwitchedOn == false)
        #expect(onOff("Ultracode", isOn: true, values: ["On", "Off"]).isSwitchedOn == true)
        #expect(ChatControl(id: "t", name: "Brief", category: nil, value: .toggle(true)).isSwitchedOn == true)
        #expect(ChatControl(id: "t", name: "Brief", category: nil, value: .toggle(false)).isSwitchedOn == false)
        // A choice that happens to be called "on" among others is not a switch.
        #expect(effort.isSwitchedOn == nil)
    }

    @Test func theSummaryNamesWhatIsOn() {
        let fast = onOff("Fast mode", isOn: true)
        let ultracode = onOff("Ultracode", isOn: true, values: ["On", "Off"])
        let brief = ChatControl(id: "t", name: "Brief", category: nil, value: .toggle(true))
        #expect(ChatControl.switchSummary(of: [effort, fast, onOff("Ultracode", isOn: false)]) == "Fast mode on")
        #expect(ChatControl.switchSummary(of: [fast, ultracode]) == "Fast mode and Ultracode on")
        #expect(ChatControl.switchSummary(of: [fast, ultracode, brief]) == "Fast mode, Ultracode, and Brief on")
    }

    @Test func nothingOnIsNothingToSay() {
        #expect(ChatControl.switchSummary(of: [effort, onOff("Fast mode", isOn: false)]) == nil)
        #expect(ChatControl.switchSummary(of: []) == nil)
    }
}

@Suite
struct LevelStopsTests {
    private func effort(_ values: [String], current: String?) -> ChatControl {
        ChatControl(
            id: "effort", name: "Effort", category: .thoughtLevel,
            value: .select(current: current, groups: [.init(name: nil, choices: values.map { ConfigOptionValue(value: $0, name: $0.capitalized) })])
        )
    }

    @Test func anOfferedDefaultIsTheFirstStopAndCanBeChosen() throws {
        let control = effort(["default", "low", "medium", "high"], current: "default")
        let scale = try #require(control.levelScale)
        let stops = scale.stops(includingDefault: false)
        #expect(stops.map(\.name) == ["Default", "Low", "Medium", "High"])
        #expect(stops.map(\.value) == ["default", "low", "medium", "high"])
        #expect(stops.map(\.isDefault) == [true, false, false, false])
        #expect(scale.isAtDefault(control))
        #expect(scale.stopIndex(of: control, in: stops) == 0)
    }

    @Test func aLevelIsAtItsOwnStopBehindTheDefault() throws {
        let control = effort(["default", "low", "medium", "high"], current: "medium")
        let scale = try #require(control.levelScale)
        #expect(!scale.isAtDefault(control))
        #expect(scale.stopIndex(of: control, in: scale.stops(includingDefault: false)) == 2)
    }

    @Test func anAgentWithoutADefaultHasOnlyItsLevels() throws {
        let control = effort(["low", "medium", "high", "xhigh"], current: "low")
        let scale = try #require(control.levelScale)
        let stops = scale.stops(includingDefault: false)
        #expect(stops.map(\.name) == ["Low", "Medium", "High", "Xhigh"])
        #expect(stops.map(\.isDefault) == [false, false, false, false])
        #expect(scale.stopIndex(of: control, in: stops) == 0)
    }

    @Test func aDefaultThatIsNotAChoiceGetsAStopThatSendsNothing() throws {
        // OpenCode reports "default" and lists only the levels.
        let control = effort(["minimal", "low", "medium", "high"], current: nil)
        let scale = try #require(control.levelScale)
        #expect(scale.isAtDefault(control))
        let stops = scale.stops(includingDefault: true)
        #expect(stops.first == ChatControl.LevelScale.Stop(name: "Default", value: nil, isDefault: true))
        #expect(stops.count == 5)
        #expect(scale.stopIndex(of: control, in: stops) == 0)
        // The stop stays where it was once a level is chosen, so the others keep their places.
        let chosen = effort(["minimal", "low", "medium", "high"], current: "low")
        #expect(scale.stopIndex(of: chosen, in: stops) == 2)
    }
}

@Suite
struct ModelSearchTests {
    private func choice(_ value: String, _ name: String? = nil) -> ConfigOptionValue {
        ConfigOptionValue(value: value, name: name ?? value)
    }

    private func models(_ groups: [ChatControl.ChoiceGroup], current: String? = nil, category: ConfigOptionCategory? = .model) -> ChatControl {
        ChatControl(id: "model", name: "Model", category: category, value: .select(current: current, groups: groups))
    }

    /// The way OpenCode lists models: flat, the provider in the id and in the name.
    private var flat: ChatControl {
        models([.init(name: nil, choices: [
            choice("anthropic/claude-fable-5", "anthropic/Claude Fable 5"),
            choice("anthropic/claude-sonnet-5", "anthropic/Claude Sonnet 5"),
            choice("openai/gpt-6-luna", "openai/GPT 6 Luna"),
            choice("local", "Local Model"),
            choice("openai/gpt-5.6-terra", "openai/GPT 5.6 Terra"),
        ])], current: "openai/gpt-6-luna")
    }

    private func sections(_ control: ChatControl, query: String = "", favorites: [String] = [], recent: [String] = []) -> [ModelSearch.Section] {
        ModelSearch.sections(of: control, query: query, favorites: favorites, recent: recent)
    }

    @Test func onlyALongModelListIsSearched() {
        func list(_ count: Int, category: ConfigOptionCategory? = .model) -> ChatControl {
            models([.init(name: nil, choices: (0..<count).map { choice("m\($0)") })], category: category)
        }
        #expect(!list(ModelSearch.threshold - 1).needsModelSearch)
        #expect(list(ModelSearch.threshold).needsModelSearch)
        #expect(!list(40, category: .mode).needsModelSearch)
        #expect(!ChatControl(id: "m", name: "Model", category: .model, value: .toggle(true)).needsModelSearch)
        // The menu starts hiding models at the same count, so no list is both split and whole.
        #expect(list(ModelSearch.threshold - 1).modelShortlist(recent: []) == nil)
        #expect(list(ModelSearch.threshold).modelShortlist(recent: []) != nil)
    }

    @Test func aFlatListIsGroupedByTheProviderInTheId() {
        let result = sections(flat)
        #expect(result.map(\.title) == ["anthropic", "openai", nil])
        #expect(result.map { $0.rows.map(\.title) } == [["Claude Fable 5", "Claude Sonnet 5"], ["GPT 6 Luna", "GPT 5.6 Terra"], ["Local Model"]])
        #expect(result.flatMap(\.rows).allSatisfy { $0.detail == nil })
    }

    @Test func theAgentsOwnGroupsAreKept() {
        let control = models([
            .init(name: "Recommended", choices: [choice("a/1", "One"), choice("b/1", "Two")]),
            .init(name: "Other", choices: [choice("a/2", "Three")]),
        ])
        #expect(sections(control).map(\.title) == ["Recommended", "Other"])
        #expect(sections(control).flatMap(\.rows).map(\.title) == ["One", "Two", "Three"])
    }

    @Test func favoritesAndRecentModelsComeFirstAndStayInTheirProvider() {
        let result = sections(
            flat, favorites: ["openai/gpt-5.6-terra", "anthropic/claude-fable-5", "gone"],
            recent: ["local", "anthropic/claude-fable-5", "gone", "openai/gpt-6-luna"]
        )
        #expect(result.map(\.title) == ["Favorites", "Recent", "anthropic", "openai", nil])
        // Favorites in the agent's order, recent ones latest first and without the favorites.
        #expect(result[0].rows.map(\.choice.value) == ["anthropic/claude-fable-5", "openai/gpt-5.6-terra"])
        #expect(result[1].rows.map(\.choice.value) == ["local", "openai/gpt-6-luna"])
        // Where providers mix, each row names its own.
        #expect(result[0].rows.map(\.detail) == ["anthropic", "openai"])
        #expect(result[0].rows.map(\.title) == ["Claude Fable 5", "GPT 5.6 Terra"])
        #expect(result[1].rows.map(\.detail) == [nil, "openai"])
        #expect(result.dropFirst(2).flatMap(\.rows).count == 5)
    }

    @Test func onlySoManyRecentModelsAreShown() {
        let control = models([.init(name: nil, choices: (0..<20).map { choice("m\($0)") })])
        let result = sections(control, recent: (0..<10).map { "m\($0)" })
        #expect(result.first?.rows.map(\.choice.value) == ["m0", "m1", "m2", "m3", "m4"])
    }

    @Test func everyRowHasAnIdOfItsOwn() {
        let twice = models([.init(name: nil, choices: [choice("a/1"), choice("a/1"), choice("a/2")])])
        let rows = sections(twice, favorites: ["a/1"], recent: ["a/2", "a/2"]).flatMap(\.rows)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.map(\.choice.value) == ["a/1", "a/2", "a/1", "a/2"])
    }

    @Test func aQueryMatchesTheNameTheIdAndTheProvider() {
        #expect(sections(flat, query: "sonnet").flatMap(\.rows).map(\.title) == ["Claude Sonnet 5"])
        #expect(sections(flat, query: "GPT-5.6").flatMap(\.rows).map(\.title) == ["GPT 5.6 Terra"])
        #expect(sections(flat, query: "openai").flatMap(\.rows).map(\.title) == ["GPT 6 Luna", "GPT 5.6 Terra"])
        #expect(sections(flat, query: "OPENAI").map(\.title) == ["openai"])
        #expect(sections(flat, query: "nothing").isEmpty)
        // A named group is a provider to search by, too.
        let grouped = models([.init(name: "Anthropic", choices: [choice("opus", "Opus")]), .init(name: "OpenAI", choices: [choice("luna", "Luna")])])
        #expect(sections(grouped, query: "anthr").flatMap(\.rows).map(\.title) == ["Opus"])
    }

    @Test func everyWordOfTheQueryHasToMatch() {
        #expect(sections(flat, query: "claude 5").flatMap(\.rows).map(\.title) == ["Claude Fable 5", "Claude Sonnet 5"])
        #expect(sections(flat, query: "anthropic son").flatMap(\.rows).map(\.title) == ["Claude Sonnet 5"])
        #expect(sections(flat, query: "claude luna").isEmpty)
        #expect(sections(flat, query: "  ").count == 3)
    }

    @Test func aQueryLeavesTheTopSectionsOut() {
        let result = sections(flat, query: "claude", favorites: ["anthropic/claude-fable-5"], recent: ["anthropic/claude-sonnet-5"])
        #expect(result.map(\.title) == ["anthropic"])
        #expect(result[0].rows.count == 2)
    }

    @Test func theKeyboardStartsOnTheModelInUse() {
        #expect(ModelSearch.initialSelection(in: sections(flat), current: "openai/gpt-6-luna") == 2)
        // Its first row, which is the one on top when it is a favorite.
        #expect(ModelSearch.initialSelection(in: sections(flat, favorites: ["openai/gpt-6-luna"]), current: "openai/gpt-6-luna") == 0)
        #expect(ModelSearch.initialSelection(in: sections(flat), current: nil) == 0)
        #expect(ModelSearch.initialSelection(in: sections(flat), current: "gone") == 0)
    }

    @Test func theProviderIsCutFromANameOnlyWhereItLeads() {
        #expect(ModelSearch.title(of: choice("a/x", "anthropic/Claude"), provider: "anthropic") == "Claude")
        #expect(ModelSearch.title(of: choice("a/x", "Anthropic/Claude"), provider: "anthropic") == "Claude")
        #expect(ModelSearch.title(of: choice("a/x", "Claude by anthropic/x"), provider: "anthropic") == "Claude by anthropic/x")
        #expect(ModelSearch.title(of: choice("a/x", "anthropic/"), provider: "anthropic") == "anthropic/")
        #expect(ModelSearch.title(of: choice("x", "Claude"), provider: nil) == "Claude")
    }

    /// The settings popover as a narrow pane fills it: mode and model moved in beside the effort
    /// and the switches.
    @MainActor
    private func popoverWidth(modelName: String) -> CGFloat {
        func select(_ id: String, _ name: String, _ category: ConfigOptionCategory?, _ choices: [String]) -> ChatControl {
            let values = choices.map { ConfigOptionValue(value: $0.lowercased(), name: $0) }
            return ChatControl(id: id, name: name, category: category, value: .select(current: values[0].value, groups: [.init(name: nil, choices: values)]))
        }
        let controls = [
            select("mode", "Mode", .mode, ["Manual", "Plan"]),
            ChatControl(id: "model", name: "Model", category: .model, value: .select(current: "anthropic/x", groups: [
                .init(name: nil, choices: [ConfigOptionValue(value: "anthropic/x", name: modelName), ConfigOptionValue(value: "anthropic/y", name: "anthropic/Y")]),
            ])),
            select("effort", "Effort", .thoughtLevel, ["Default", "Low", "Medium", "High"]),
            select("fast", "Fast mode", nil, ["Off", "On"]),
            select("ultracode", "Ultracode", .modelConfig, ["Off", "On"]),
        ]
        let host = NSHostingView(rootView: ControlsPopover(controls: controls, select: { _, _ in }, setToggle: { _, _ in }))
        return host.fittingSize.width
    }

    @MainActor
    @Test func theSettingsPopoverGrowsWithItsValuesAndNeverSqueezesItsNames() {
        let padding: CGFloat = 32
        let short = popoverWidth(modelName: "anthropic/Fable")
        // Never narrower than the slider wants, and not as wide as a popover may get either,
        // which is what a slider left to itself asks for.
        #expect(short >= ControlsPopover.minimumWidth + padding)
        #expect(short < 420)
        // A long name makes it wider instead of taking the name column's room, up to the cut.
        let long = popoverWidth(modelName: "anthropic/Claude Fable 5.2 with extended thinking (preview)")
        #expect(long > short)
        #expect(long < 420)
        #expect(popoverWidth(modelName: "anthropic/" + String(repeating: "Claude Fable ", count: 20)) < 420)
    }

    @Test func aRowArrivingUnderARestingPointerIsNotPointedAt() {
        let pointer = PointerLocation()
        // The list opened under the pointer, then scrolled under it, then changed its rows.
        #expect(!pointer.moved(to: CGPoint(x: 100, y: 200)))
        #expect(!pointer.moved(to: CGPoint(x: 100, y: 200)))
        #expect(!pointer.moved(to: CGPoint(x: 100, y: 200)))
        // The pointer itself moving is what selects.
        #expect(pointer.moved(to: CGPoint(x: 100, y: 203)))
        #expect(!pointer.moved(to: CGPoint(x: 100, y: 203)))
    }

    @Test func favoritesAreToggledAndKeptPerAgent() {
        var stored = ""
        stored = FavoriteModels.toggling("a", in: stored)
        stored = FavoriteModels.toggling("b", in: stored)
        #expect(FavoriteModels.values(in: stored) == ["a", "b"])
        stored = FavoriteModels.toggling("a", in: stored)
        #expect(FavoriteModels.values(in: stored) == ["b"])
        #expect(FavoriteModels.values(in: FavoriteModels.toggling("b", in: stored)).isEmpty)
        #expect(FavoriteModels.key(agentName: "OpenCode") != FavoriteModels.key(agentName: "Claude Code"))
        #expect(FavoriteModels.key(agentName: "OpenCode") != RecentModels.key(agentName: "OpenCode"))
    }
}
