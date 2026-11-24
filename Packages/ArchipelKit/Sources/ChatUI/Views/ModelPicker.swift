import ACPKit
import SwiftUI
import UISupport

/// A model list too long for a menu: a search field over the favorites, the models chosen before
/// and every model by provider. The keyboard stays in the field, as it does in the command list:
/// typing filters, the arrows move the selection, Return chooses, Command-D stars the selected
/// model and Esc closes.
struct ModelPicker: View {
    let control: ChatControl
    /// Latest first.
    let recentModels: [String]
    let choose: @MainActor (String) -> Void

    @AppStorage private var favorites: String
    @State private var query = ""
    @State private var selection = 0
    /// Counts the moves made with the keyboard. The list scrolls to follow those, and not the
    /// pointer's.
    @State private var keyboardMoves = 0
    /// Where the pointer was at the last hover report. A row that arrives under a resting
    /// pointer, because the list scrolled or its rows changed, reports a hover as well, and must
    /// not take the selection from the keyboard: Return would then choose the model under the
    /// pointer instead of the top match. Kept by reference, since nothing drawn depends on it.
    @State private var pointer = PointerLocation()
    @FocusState private var isSearching: Bool
    @Environment(\.dismiss) private var dismiss

    private static let width: CGFloat = 300
    private static let rowHeight: CGFloat = 26
    private static let headerHeight: CGFloat = 22
    private static let inset: CGFloat = 6
    private static let maximumListHeight: CGFloat = 330
    private static let top = "top"

    init(control: ChatControl, recentModels: [String], agentName: String?, choose: @escaping @MainActor (String) -> Void) {
        self.control = control
        self.recentModels = recentModels
        self.choose = choose
        _favorites = AppStorage(wrappedValue: "", FavoriteModels.key(agentName: agentName ?? ""))
    }

    private var current: String? { control.currentValue }

    private func sections(query: String) -> [ModelSearch.Section] {
        ModelSearch.sections(of: control, query: query, favorites: FavoriteModels.values(in: favorites), recent: recentModels)
    }

    var body: some View {
        let sections = sections(query: query)
        let rows = sections.flatMap(\.rows)
        VStack(spacing: 0) {
            searchField(rows: rows)
            Divider()
            list(sections: sections, rows: rows)
        }
        .frame(width: Self.width)
        // The popover hangs on the bar and would take the bar's gray along.
        .foregroundStyle(.primary)
        .background {
            // The keyboard stays in the search field, so the star needs a key of its own.
            Button("Toggle Favorite") {
                if rows.indices.contains(selection) { toggleFavorite(rows[selection]) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onExitCommand { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Models")
        .accessibilityIdentifier("chat.models")
    }

    private func searchField(rows: [ModelSearch.Row]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Models", text: $query, prompt: Text("Search models"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($isSearching)
                .onKeyPress(.downArrow) { move(1, count: rows.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: rows.count); return .handled }
                .onSubmit {
                    if rows.indices.contains(selection) { choose(rows[selection].choice.value) }
                }
                .onChange(of: query) {
                    selection = 0
                    keyboardMoves += 1
                }
                .accessibilityIdentifier("chat.models.search")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func list(sections: [ModelSearch.Section], rows: [ModelSearch.Row]) -> some View {
        let favorites = FavoriteModels.values(in: favorites)
        return ScrollViewReader { proxy in
            ScrollView {
                // Lazy: OpenCode lists every model of every provider the user has signed in to.
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top)
                    ForEach(sections) { section in
                        if let title = section.title {
                            Text(verbatim: title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.leading, ModelRow.titleInset)
                                .frame(height: Self.headerHeight, alignment: .bottomLeading)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.rows) { row in
                            let isSelected = rows.indices.contains(selection) && rows[selection].id == row.id
                            ModelRow(
                                row: row, isCurrent: row.choice.value == current, isSelected: isSelected,
                                isFavorite: favorites.contains(row.choice.value),
                                choose: { choose(row.choice.value) },
                                toggleFavorite: { toggleFavorite(row) },
                                hovered: {
                                    guard pointer.moved(to: NSEvent.mouseLocation) else { return }
                                    if let index = rows.firstIndex(where: { $0.id == row.id }) { selection = index }
                                }
                            )
                            .frame(height: Self.rowHeight)
                            .id(row.id)
                        }
                    }
                }
                .padding(Self.inset)
            }
            // As tall as the whole list wants to be, and no taller or shorter for what is typed:
            // a popover that resizes with every character moves the field away from the caret.
            .frame(height: min(Self.height(of: self.sections(query: "")), Self.maximumListHeight))
            .overlay {
                if rows.isEmpty {
                    Text("No models match “\(query)”.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            }
            .onChange(of: keyboardMoves) {
                guard rows.indices.contains(selection) else { return }
                // The first row takes its section's title along.
                if selection == 0 { proxy.scrollTo(Self.top, anchor: .top) } else { proxy.scrollTo(rows[selection].id) }
            }
            .onAppear {
                isSearching = true
                selection = ModelSearch.initialSelection(in: sections, current: current)
                if selection > 0 { proxy.scrollTo(rows[selection].id, anchor: .center) }
            }
        }
    }

    private static func height(of sections: [ModelSearch.Section]) -> CGFloat {
        sections.reduce(inset * 2) { height, section in
            height + (section.title == nil ? 0 : headerHeight + 2) + CGFloat(section.rows.count) * rowHeight
        }
    }

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        selection = CompletionSelection.index(selection, movedBy: step, count: count)
        keyboardMoves += 1
    }

    private func toggleFavorite(_ row: ModelSearch.Row) {
        let before = sections(query: query).flatMap(\.rows)
        let selected = before.indices.contains(selection) ? before[selection].id : nil
        favorites = FavoriteModels.toggling(row.choice.value, in: favorites)
        // The favorites are the first section, so every row below moves. The selection stays
        // with its row, not with the place the row had.
        let rows = sections(query: query).flatMap(\.rows)
        selection = rows.firstIndex { $0.id == selected } ?? min(selection, max(rows.count - 1, 0))
    }
}

/// The pointer's place on screen, to tell a pointer that moved from a list that moved under it.
final class PointerLocation {
    private var last: CGPoint?

    /// Whether the pointer is somewhere else than at the last call. The first call only takes
    /// note of where it is: a list that opens under the pointer was not pointed at.
    func moved(to location: CGPoint) -> Bool {
        defer { last = location }
        guard let last else { return false }
        return last != location
    }
}

/// One model: a checkmark when it is the one in use, its name, and a star to keep it on top.
private struct ModelRow: View {
    let row: ModelSearch.Row
    let isCurrent: Bool
    let isSelected: Bool
    let isFavorite: Bool
    let choose: @MainActor () -> Void
    let toggleFavorite: @MainActor () -> Void
    let hovered: @MainActor () -> Void

    private static let checkWidth: CGFloat = 12
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 8
    /// Where a row's name starts, which is where the section titles start too.
    static let titleInset = padding + checkWidth + spacing

    var body: some View {
        HStack(spacing: 0) {
            Button(action: choose) {
                HStack(spacing: Self.spacing) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: Self.checkWidth)
                        .opacity(isCurrent ? 1 : 0)
                        .accessibilityHidden(true)
                    Text(verbatim: row.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let detail = row.detail {
                        Text(verbatim: detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(row.choice.description ?? row.choice.name)
            .accessibilityLabel(row.detail.map { "\(row.title), \($0)" } ?? row.title)
            .accessibilityValue(isCurrent ? "In use" : "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            // The star below is only there for some rows and names no model. As an action of the
            // row, every model offers it.
            .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites", toggleFavorite)
            .accessibilityIdentifier("chat.models.choice")

            // A star that is off shows only on the row the pointer or the arrows are on, so the
            // list stays a list of names.
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star", action: toggleFavorite)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(isFavorite ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 22)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .opacity(isFavorite || isSelected ? 1 : 0)
                .help(isFavorite ? "Remove from Favorites (⌘D)" : "Add to Favorites (⌘D)")
                .accessibilityHidden(true)
        }
        .padding(.leading, Self.padding)
        .padding(.trailing, 2)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .fill(.quaternary)
            }
        }
        // Continuous, so that moving inside a row counts too: after the keyboard took the
        // selection away, a nudge of the pointer gives it back to the row it is on.
        .onContinuousHover { phase in
            if case .active = phase { hovered() }
        }
    }
}

#if DEBUG
#Preview("Model Picker") {
    let providers = ["anthropic": ["Claude Fable 5.2", "Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 4.5 (latest)"],
                     "openai": ["GPT 6 Luna", "GPT 5.6 Terra", "GPT 5.6 Luna"],
                     "localprovider": ["Gemma 4 E4B", "Gemma 4 26b-a4b (local)", "Embeddinggemma 2"]]
    let choices = providers.keys.sorted().flatMap { provider in
        providers[provider, default: []].map { name in
            ConfigOptionValue(value: "\(provider)/\(name.lowercased().replacing(" ", with: "-"))", name: "\(provider)/\(name)")
        }
    }
    let control = ChatControl(
        id: "model", name: "Model", category: .model,
        value: .select(current: choices[1].value, groups: [.init(name: nil, choices: choices)])
    )
    return ModelPicker(control: control, recentModels: [choices[5].value, choices[1].value], agentName: nil, choose: { _ in })
}
#endif
