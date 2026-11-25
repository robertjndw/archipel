import AppKit
import ArchipelCore
import SwiftUI

/// A row of swatches for choosing a tint. With `automaticLabel` set, the first swatch is a dashed
/// circle that stands for "no tint chosen" and selects nil. The last swatch picks any color with
/// the system color panel.
struct TintSwatchPicker: View {
    @Binding var selection: Tint?
    var automaticLabel: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var colorPanel = ColorPanelLink()
    /// Lets the custom swatch keep its color while the user tries out a preset.
    @State private var lastCustom: Tint?

    var body: some View {
        HStack(spacing: 0) {
            if let automaticLabel {
                swatch(nil, label: automaticLabel, ring: .secondary) {
                    Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }
            }
            ForEach(Tint.presets, id: \.self) { candidate in
                swatch(candidate, label: candidate.displayName, ring: candidate.color) {
                    Circle().fill(candidate.color.gradient)
                }
            }
            customSwatch
        }
        .animation(reduceMotion ? nil : Motion.selection, value: selection)
        .onAppear { lastCustom = selection?.isCustom == true ? selection : nil }
        .onChange(of: selection) { _, new in
            if new?.isCustom == true { lastCustom = new } else { colorPanel.detach() }
        }
        .onDisappear { colorPanel.detach() }
    }

    private var customSwatch: some View {
        let custom = selection?.isCustom == true ? selection : nil
        return swatch(custom, label: "Custom Color…", ring: custom?.color ?? .secondary, isSelected: custom != nil) {
            if let custom {
                Circle().fill(custom.color.gradient)
            } else {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .teal, .blue, .purple, .pink, .red], center: .center))
            }
        } action: {
            let start = lastCustom ?? selection.flatMap { Tint(NSColor($0.color)) } ?? .custom(red: 0, green: 122, blue: 255)
            selection = start
            colorPanel.show(start.color) { picked in selection = picked }
        }
    }

    private func swatch(
        _ value: Tint?,
        label: String,
        ring: Color,
        isSelected: Bool? = nil,
        @ViewBuilder _ content: () -> some View,
        action: (() -> Void)? = nil
    ) -> some View {
        let isSelected = isSelected ?? (selection == value)
        return Button {
            if let action { action() } else { selection = value }
        } label: {
            content()
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(ring, lineWidth: 2)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Hooks the shared color panel up to one picker. The panel outlives the sheet, so the picker has
/// to unhook it when it closes or a preset is chosen. Otherwise a later drag in the panel would
/// still recolor the island.
@MainActor
private final class ColorPanelLink: NSObject {
    /// NSColorPanel has no getter for its target.
    private static weak var owner: ColorPanelLink?
    private var onChange: ((Tint) -> Void)?

    func show(_ color: Color, onChange: @escaping (Tint) -> Void) {
        let panel = NSColorPanel.shared
        // Drop the old target first, or setting the color below would send it to the previous picker.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(color)
        self.onChange = onChange
        Self.owner = self
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    func detach() {
        guard onChange != nil else { return }
        onChange = nil
        let panel = NSColorPanel.shared
        if Self.owner === self {
            Self.owner = nil
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.orderOut(nil)
        }
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        if let tint = Tint(sender.color) { onChange?(tint) }
    }
}
