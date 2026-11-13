import ArchipelCore
import SwiftUI

/// The row of islands at the bottom of the sidebar. An island that is not
/// selected still shows a dot when a session inside it wants the user.
struct IslandSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var editor: IslandEditor.Mode?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(model.workspace.islands) { island in
                        islandButton(island)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)

            Button("New Island", systemImage: "plus") { editor = .create }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.trailing, 10)
                .help("New Island")
        }
        .padding(.vertical, 8)
        .sheet(item: $editor) { mode in
            IslandEditor(mode: mode)
        }
    }

    private func islandButton(_ island: Island) -> some View {
        let isSelected = island.id == model.selectedIsland?.id
        let summary = attentionSummary(of: island, activities: model.activities)
        return Button {
            model.select(island: island.id)
        } label: {
            Image(systemName: island.symbol)
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? AnyShapeStyle(island.tint.color) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 26)
                .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if summary.needsAttention > 0 || summary.unread > 0 {
                        Circle()
                            .fill(summary.needsAttention > 0 ? Color.orange : island.tint.color)
                            .frame(width: 7, height: 7)
                            .offset(x: -3, y: 3)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(island.name)
        .accessibilityLabel(island.name)
        .accessibilityValue(accessibilityValue(summary))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Edit Island…") { editor = .edit(island) }
            Button("Delete Island", role: .destructive) { model.removeIsland(island.id) }
                .disabled(model.workspace.islands.count < 2)
        }
    }

    private func accessibilityValue(_ summary: AttentionSummary) -> String {
        if summary.needsAttention > 0 { return "\(summary.needsAttention) waiting for you" }
        if summary.unread > 0 { return "\(summary.unread) unread" }
        return ""
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
        "music.note", "paintbrush", "shippingbox", "star",
    ]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var name = ""
    @State private var symbol = IslandEditor.symbols[0]
    @State private var tint = Tint.blue

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Color", selection: $tint) {
                ForEach(Tint.allCases, id: \.self) { tint in
                    Label(tint.displayName, systemImage: "circle.fill")
                        .tint(tint.color)
                        .tag(tint)
                }
            }
            LabeledContent("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                    ForEach(Self.symbols, id: \.self) { candidate in
                        Button {
                            symbol = candidate
                        } label: {
                            Image(systemName: candidate)
                                .frame(width: 30, height: 26)
                                .foregroundStyle(candidate == symbol ? AnyShapeStyle(tint.color) : AnyShapeStyle(.secondary))
                                .background(candidate == symbol ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(candidate)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
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
