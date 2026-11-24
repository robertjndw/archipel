import ACPKit
import SwiftUI
import UISupport

/// The agent's slash commands that match what is being typed, floating above the composer.
/// The keyboard stays in the composer; this only shows the selection and takes clicks.
struct SlashCommandList: View {
    let commands: [AvailableCommand]
    let selection: Int
    let choose: @MainActor (AvailableCommand) -> Void

    private static let rowHeight: CGFloat = 30
    private static let inset: CGFloat = 6
    private static let visibleRows: CGFloat = 7
    private static let radius = ChatMetrics.surfaceRadius

    /// Known without measuring, so the composer can place the list above itself.
    static func height(for count: Int) -> CGFloat {
        min(CGFloat(count), visibleRows) * rowHeight + inset * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: Claude sends about 135 commands, and the list opens on every "/".
                LazyVStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        row(command, isSelected: index == selection)
                            .id(command.id)
                    }
                }
                .padding(Self.inset)
            }
            .onChange(of: selection) {
                guard commands.indices.contains(selection) else { return }
                proxy.scrollTo(commands[selection].id)
            }
        }
        .frame(maxWidth: 460)
        .frame(height: Self.height(for: commands.count))
        .glassEffect(.regular, in: .rect(cornerRadius: Self.radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
        .accessibilityIdentifier("chat.commands")
    }

    private func row(_ command: AvailableCommand, isSelected: Bool) -> some View {
        Button {
            choose(command)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "/\(SlashCommands.displayName(command))")
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: command.description)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .background {
                if isSelected {
                    // Concentric with the panel: its radius less the inset.
                    RoundedRectangle(cornerRadius: CornerRadius.concentric(Self.radius, inset: Self.inset), style: .continuous)
                        .fill(.quaternary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(SlashCommands.displayName(command)), \(command.description)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
