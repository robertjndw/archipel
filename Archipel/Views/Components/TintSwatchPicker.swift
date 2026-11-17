import ArchipelCore
import SwiftUI

/// A row of swatches for choosing a tint. With `automaticLabel` set, the first swatch is a dashed
/// circle that stands for "no tint chosen" and selects nil.
struct TintSwatchPicker: View {
    @Binding var selection: Tint?
    var automaticLabel: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if let automaticLabel {
                swatch(nil, label: automaticLabel, ring: .secondary) {
                    Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }
            }
            ForEach(Tint.allCases, id: \.self) { candidate in
                swatch(candidate, label: candidate.displayName, ring: candidate.color) {
                    Circle().fill(candidate.color.gradient)
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.selection, value: selection)
    }

    private func swatch(
        _ value: Tint?,
        label: String,
        ring: Color,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        Button {
            selection = value
        } label: {
            content()
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay {
                    if selection == value {
                        Circle().strokeBorder(ring, lineWidth: 2)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}
