import SwiftUI

/// Picks any SF Symbol: a short list of suggestions up front, and every symbol on the system behind
/// a search field and the SF Symbols app's categories.
struct SymbolPicker: View {
    @Binding var selection: String
    let suggestions: [String]
    let tint: Color
    /// Off where the icon is drawn filled on its own, so `star` and `star.fill` would look the same.
    var includesFillVariants = true
    @State private var query = ""
    @State private var category = SymbolPicker.suggested.id

    private static let suggested = SymbolCatalog.Category(id: "suggested", title: "Suggested", icon: "star")
    private let catalog = SymbolCatalog.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        let results = self.results
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                searchField
                if !catalog.symbols.isEmpty {
                    categoryMenu
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(results, id: \.self) { candidate in
                            cell(candidate)
                        }
                    }
                    .padding(.vertical, 2)
                }
                // The island editor's form turns scrolling off for itself, and that reaches in here.
                .scrollDisabled(false)
                .frame(height: gridHeight(for: results.count))
                .overlay {
                    if results.isEmpty { ContentUnavailableView.search(text: query) }
                }
                .onAppear {
                    if !suggestions.contains(selection), catalog.symbols.contains(selection) {
                        category = SymbolCatalog.all.id
                    }
                    // A frame later, once the grid knows which category it shows.
                    DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
                }
                .onChange(of: category) { scrollToTop(proxy, results: self.results) }
                .onChange(of: query) { scrollToTop(proxy, results: self.results) }
            }
        }
        .padding(.vertical, 4)
    }

    /// Drawn by hand: a grouped form turns any bordered text field into a labeled row, which
    /// leaves an empty label column and pushes the field into the far corner.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // A prompt, not a title: in the editor's grouped form a title becomes a row label,
            // which wraps onto two lines next to an empty field.
            TextField(text: $query, prompt: Text("Search Symbols")) { EmptyView() }
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(1)
                // Return after typing a search means "this one". Without a handler of its own the
                // field passes the key on to the sheet's default button, which saves and closes
                // before any symbol was picked.
                .onSubmit {
                    if !query.isEmpty, let first = results.first { selection = first }
                }
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: Chrome.controlRadius, style: .continuous))
        .disabled(catalog.symbols.isEmpty)
    }

    private var categories: [SymbolCatalog.Category] {
        [Self.suggested, SymbolCatalog.all] + catalog.categories
    }

    private var results: [String] {
        if category == Self.suggested.id {
            // Searching only the suggestions would find next to nothing, so a query looks everywhere.
            return query.isEmpty
                ? suggestions
                : catalog.search(query, in: SymbolCatalog.all.id, includingFills: includesFillVariants)
        }
        return catalog.search(query, in: category, includingFills: includesFillVariants)
    }

    private var categoryMenu: some View {
        let current = categories.first { $0.id == category } ?? Self.suggested
        return Menu {
            Picker("Category", selection: $category) {
                ForEach(categories) { category in
                    Label(category.title, systemImage: category.icon).tag(category.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(current.title, systemImage: current.icon)
        }
        .menuStyle(.button)
        .fixedSize()
        .untinted()
        .help("Symbol Category")
    }

    private func cell(_ candidate: String) -> some View {
        let isChosen = candidate == selection
        return Button {
            selection = candidate
        } label: {
            Image(systemName: candidate)
                .font(.system(size: 15))
                .frame(width: 34, height: 34)
                .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background(
                    isChosen ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: .rect(cornerRadius: Chrome.controlRadius, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(candidate)
        .accessibilityLabel(candidate.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// Fits the rows there are, up to a little over five, so a short list of suggestions leaves no
    /// empty space and a long one shows that it scrolls. An empty result keeps room for its message.
    private func gridHeight(for count: Int) -> CGFloat {
        let rowHeight: CGFloat = 34
        let rows = (count + columns.count - 1) / columns.count
        let content = CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * 6 + 4
        return min(max(content, 120), 220)
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, results: [String]) {
        if let first = results.first { proxy.scrollTo(first, anchor: .top) }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var selection = "leaf"
    SymbolPicker(selection: $selection, suggestions: IslandEditor.symbols, tint: .teal)
        .frame(width: 340)
        .padding()
}

#Preview("Beyond the suggestions") {
    @Previewable @State var selection = "tortoise"
    SymbolPicker(selection: $selection, suggestions: IslandEditor.symbols, tint: .orange)
        .frame(width: 340)
        .padding()
}
#endif
