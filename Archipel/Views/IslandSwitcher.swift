import ArchipelCore
import SwiftUI

/// The islands ("spaces") at the bottom of the sidebar: one glass capsule floating over the list, the
/// selected island spelled out, the others as icons that badge what is going on inside them.
///
/// The sidebar itself is already glass, so the capsule is the only glass here. The selection is a
/// tinted fill inside it rather than glass of its own, which would stack glass on glass.
struct IslandSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var editor: IslandEditor.Mode?
    @State private var deleting: Island?
    @Namespace private var selection

    /// Room for the new island button on the trailing side, mirrored on the leading side so the
    /// capsule stays centered in the sidebar.
    private static let gutter: CGFloat = 34

    var body: some View {
        let islands = model.workspace.islands
        let selectedID = model.selectedIsland?.id
        let summaries = model.islandSummaries()

        // ViewThatFits takes the plain row while it fits, so the capsule hugs and centers the islands;
        // only when it does not does the scrolling variant take the full width.
        ViewThatFits(in: .horizontal) {
            row(islands, selectedID: selectedID, summaries: summaries)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    row(islands, selectedID: selectedID, summaries: summaries)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedID, initial: true) {
                    guard let selectedID else { return }
                    withAnimation(.smooth) { proxy.scrollTo(selectedID, anchor: .center) }
                }
            }
        }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, Self.gutter)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Button("New Island", systemImage: "plus") { editor = .create }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("New Island")
                .frame(width: Self.gutter)
        }
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.3), value: selectedID)
        .sheet(item: $editor) { mode in
            IslandEditor(mode: mode)
        }
        .confirmationDialog(
            "Delete the island \(deleting?.name ?? "")?",
            item: $deleting
        ) { island in
            Button("Delete Island", role: .destructive) { model.removeIsland(island.id) }
        } message: { island in
            let count = island.projects.count
            Text(count == 1
                ? "Its project is removed from Archipel and its sessions are closed. Nothing is deleted from disk."
                : "Its \(count) projects are removed from Archipel and their sessions are closed. Nothing is deleted from disk.")
        }
    }

    private func row(_ islands: [Island], selectedID: Island.ID?, summaries: [Island.ID: AttentionSummary]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(islands.enumerated()), id: \.element.id) { index, island in
                IslandButton(
                    island: island,
                    isSelected: island.id == selectedID,
                    summary: summaries[island.id] ?? .zero,
                    shortcutIndex: index < 9 ? index + 1 : nil,
                    selection: selection
                ) {
                    model.select(island: island.id)
                }
                .id(island.id)
                .contextMenu { menu(for: island) }
            }
        }
        .padding(3)
    }

    @ViewBuilder
    private func menu(for island: Island) -> some View {
        Button("Edit Island…", systemImage: "pencil") { editor = .edit(island) }
        Button("New Island…", systemImage: "plus") { editor = .create }
        Divider()
        Button("Delete Island…", systemImage: "trash", role: .destructive) {
            // An empty island has nothing to lose, so it goes without asking.
            if island.projects.isEmpty { model.removeIsland(island.id) } else { deleting = island }
        }
        .disabled(model.workspace.islands.count < 2)
    }
}

private struct IslandButton: View {
    let island: Island
    let isSelected: Bool
    let summary: AttentionSummary
    let shortcutIndex: Int?
    let selection: Namespace.ID
    let action: () -> Void

    var body: some View {
        let tint = island.tint.color
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: island.symbol)
                    .symbolVariant(isSelected ? .fill : .none)
                    .contentTransition(.symbolEffect(.replace))
                    // A slow pulse on an island you are not looking at says agents are busy there.
                    .symbolEffect(.pulse, options: .repeating, isActive: summary.working > 0 && !isSelected)
                    .symbolEffect(.bounce, options: .nonRepeating, value: summary.needsAttention)
                    .frame(width: 16)
                if isSelected {
                    Text(island.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Capped, but never wider than the name: a bare maxWidth would take all 96pt.
                        .frame(maxWidth: 96)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, isSelected ? 8 : 5)
            .frame(height: 22)
            .background {
                if isSelected {
                    Capsule()
                        .fill(tint.opacity(0.18))
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .overlay(alignment: .topTrailing) {
                badge(tint: tint)
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .animation(.smooth, value: summary)
        .help(help)
        .accessibilityLabel(island.name)
        .accessibilityValue(summary.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func badge(tint: Color) -> some View {
        switch summary.dominant {
        case .needsAttention(let count):
            SidebarAttentionBadge(signal: .needsAttention(count))
                .offset(x: 3, y: -3)
        case .unread:
            SidebarAttentionBadge(signal: .unread, tint: tint)
                .offset(x: -2, y: 2)
        case .working, nil:
            EmptyView()
        }
    }

    private var help: String {
        let shortcut = shortcutIndex.map { " (⌃\($0))" } ?? ""
        let state = summary.accessibilityDescription
        return state.isEmpty ? island.name + shortcut : "\(island.name)\(shortcut): \(state)"
    }
}

struct IslandEditor: View {
    enum Mode: Identifiable {
        case create
        case edit(Island)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let island): island.id.uuidString
            }
        }
    }

    static let symbols = [
        "square.stack.3d.up", "house", "briefcase", "building.2", "person.2", "heart",
        "globe", "leaf", "flask", "hammer", "book", "gamecontroller",
        "music.note", "paintbrush", "shippingbox", "star", "bolt", "cloud",
        "terminal", "cpu", "graduationcap", "camera", "cart", "airplane",
    ]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var name = ""
    @State private var symbol = IslandEditor.symbols[0]
    @State private var tint = Tint.blue

    var body: some View {
        VStack(spacing: 0) {
            preview
                .padding(.top, 24)
                .padding(.bottom, 8)
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Island Name"))
                }
                Section("Color") {
                    swatches
                }
                Section("Icon") {
                    symbolGrid
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Create") { commit() }
                    .disabled(trimmedName.isEmpty)
            }
        }
        .onAppear {
            if case .edit(let island) = mode {
                name = island.name
                symbol = island.symbol
                tint = island.tint
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolVariant(.fill)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 60, height: 60)
                .background(tint.color.gradient, in: .rect(cornerRadius: 15, style: .continuous))
                .animation(.snappy, value: tint)
                .animation(.snappy, value: symbol)
            Text(trimmedName.isEmpty ? (isEditing ? "Island" : "New Island") : trimmedName)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(trimmedName.isEmpty ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(Tint.allCases, id: \.self) { candidate in
                Button {
                    tint = candidate
                } label: {
                    Circle()
                        .fill(candidate.color.gradient)
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay {
                            if candidate == tint {
                                Circle().strokeBorder(candidate.color, lineWidth: 2)
                            }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help(candidate.displayName)
                .accessibilityLabel(candidate.displayName)
                .accessibilityAddTraits(candidate == tint ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: tint)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(Self.symbols, id: \.self) { candidate in
                let isChosen = candidate == symbol
                Button {
                    symbol = candidate
                } label: {
                    Image(systemName: candidate)
                        .font(.system(size: 15))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background(
                            isChosen ? AnyShapeStyle(tint.color.gradient) : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: .rect(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy(duration: 0.2), value: symbol)
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        switch mode {
        case .create: model.addIsland(name: trimmedName, symbol: symbol, tint: tint)
        case .edit(let island): model.updateIsland(island.id, name: trimmedName, symbol: symbol, tint: tint)
        }
        dismiss()
    }
}
