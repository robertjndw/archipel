import ACPKit
import SwiftUI

/// How hard the agent thinks, as a slider with a stop per level: the name and the chosen level
/// above, the track below, the way System Settings lays out its stepped sliders.
///
/// Leaving the level to the agent is a stop as well, the first one and the only one with its
/// name under it. The thumb rests there as firmly as on any level.
struct LevelSlider: View {
    let control: ChatControl
    let scale: ChatControl.LevelScale
    /// Returns once the agent has answered.
    let select: @MainActor (String, String) async -> Void

    /// The stop the thumb is at. The agent's answer arrives a moment after a drag, and a thumb
    /// bound to the control alone would jump back to the old level until it does.
    @State private var position: Int?
    /// The levels asked for and not answered yet. A drag over two stops asks twice, and the
    /// answer to the first must not pull the thumb back to the stop it has already left.
    @State private var pending = 0
    /// Once the default has a stop, it keeps it while the popover is open. With an agent whose
    /// default is not one of its choices the stop would otherwise go the moment the thumb leaves
    /// it, and a track that gets shorter under a drag moves the thumb to another level.
    @State private var keepsDefaultStop = false

    var body: some View {
        let isAtDefault = scale.isAtDefault(control)
        let stops = scale.stops(includingDefault: keepsDefaultStop || isAtDefault)
        let index = min(position ?? scale.stopIndex(of: control, in: stops), stops.count - 1)
        let last = Double(stops.count - 1)
        // A default with nothing to send cannot be chosen again once the thumb has left it. The
        // slider itself keeps the thumb off that stop: a binding that only ignores the value
        // would leave the thumb lying there on a level the agent was never told about.
        let leftDefaultBehind = index > 0 && stops[0].isDefault && stops[0].value == nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: control.name)
                Spacer(minLength: 12)
                Text(verbatim: stops[index].name)
                    .foregroundStyle(.secondary)
            }
            // Here and not around the slider, whose role VoiceOver would read the help as.
            .help(control.description ?? "")
            Slider(
                value: Binding(
                    get: { Double(index) },
                    set: { move(to: Int($0.rounded()), from: index, in: stops) }
                ),
                in: 0...last,
                step: 1,
                enabledBounds: leftDefaultBehind ? 1...last : nil,
                label: { Text(verbatim: control.name) },
                tick: { value in
                    guard stops.indices.contains(Int(value)) else { return nil }
                    let stop = stops[Int(value)]
                    guard stop.isDefault else { return SliderTick(value) }
                    return SliderTick(value) { Text(verbatim: stop.name).foregroundStyle(.secondary) }
                }
            )
            .labelsHidden()
            // A haptic tick at each stop, on a Force Touch trackpad. By the stop shown, so the
            // agent's answer handing the thumb back to the control is no second tick.
            .sensoryFeedback(.levelChange, trigger: index)
            // Named by the label above; a second label would be read as "Effort, Effort".
            .accessibilityValue(stops[index].name)
            .accessibilityIdentifier("chat.control.\(control.id)")
        }
        .onChange(of: isAtDefault, initial: true) {
            if isAtDefault { keepsDefaultStop = true }
        }
        // A level the agent changes by itself. While an answer is outstanding the thumb stays
        // where it was put: `move` hands it back once the last one is in.
        .onChange(of: control.currentValue) {
            if pending == 0 { position = nil }
        }
    }

    private func move(to index: Int, from shown: Int, in stops: [ChatControl.LevelScale.Stop]) {
        guard stops.indices.contains(index), index != shown, let value = stops[index].value else { return }
        position = index
        pending += 1
        Task {
            await select(control.id, value)
            pending -= 1
            // The agent has the last word. With every request answered the thumb goes back to
            // what the control says, whether the agent took the level, refused it or never got
            // the request, and a refused level does not stay on show.
            if pending == 0 { position = nil }
        }
    }
}
