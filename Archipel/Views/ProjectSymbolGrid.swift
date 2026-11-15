import SwiftUI

/// A selectable grid of SF Symbols that suit software projects.
struct ProjectSymbolGrid: View {
    static let symbols = [
        "shippingbox", "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "hammer", "wrench.and.screwdriver", "gearshape", "cpu",
        "server.rack", "externaldrive", "internaldrive", "network",
        "globe", "cloud", "antenna.radiowaves.left.and.right", "bolt",
        "flame", "leaf", "swift", "app.badge",
        "macwindow", "iphone", "safari", "doc.text",
        "book", "chart.bar", "cube", "puzzlepiece",
        "lock.shield", "testtube.2", "ladybug", "sparkles",
    ]

    let selection: String
    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(minimum: 32), spacing: 6), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Self.symbols, id: \.self) { symbol in
                Button { onSelect(symbol) } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if symbol == selection {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.tint.opacity(0.25))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(symbol == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview {
    @Previewable @State var selection = "swift"
    ProjectSymbolGrid(selection: selection) { selection = $0 }
        .frame(width: 340)
        .padding()
}
#endif
