import AppKit
import SwiftUI

/// The cup next to the island switcher. Lit while Archipel holds off system sleep; its menu picks the mode.
///
/// A plain button that pops an AppKit menu rather than a SwiftUI `Menu`: a `Menu` is drawn by AppKit,
/// which tints its icon with the accent color whatever foreground style it is given, so the cup could
/// never go grey.
struct StayAwakeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stayAwake = model.stayAwake
        Button(title, systemImage: stayAwake.isHolding ? "cup.and.heat.waves.fill" : "cup.and.saucer") {
            showMenu()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .contentTransition(.symbolEffect(.replace))
        // Colored whenever the feature is on, so "While Agents Are Working" does not look off while idle.
        // The steam on the icon is what says sleep is being held right now.
        .foregroundStyle(stayAwake.mode != .off ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(help)
    }

    private func showMenu() {
        let stayAwake = model.stayAwake
        let target = ModeMenuTarget { stayAwake.mode = $0 }
        let menu = NSMenu()
        menu.addItem(withTitle: "Keep Mac Awake", action: nil, keyEquivalent: "").isEnabled = false
        for mode in StayAwake.Mode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(ModeMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = mode
            item.state = mode == stayAwake.mode ? .on : .off
            menu.addItem(item)
        }
        // Opens with the current mode under the pointer, the way a pop-up button does. popUp blocks
        // until the menu closes, which keeps `target` alive for as long as an item can be chosen.
        let current = menu.items.first { $0.state == .on }
        menu.popUp(positioning: current, at: NSEvent.mouseLocation, in: nil)
    }

    private var title: String {
        model.stayAwake.isHolding ? "Keeping Mac Awake" : "Mac Can Sleep"
    }

    private var help: String {
        let state = switch model.stayAwake.mode {
        case .off: "Stay awake is off. The Mac sleeps as usual."
        case .whileWorking where model.stayAwake.isHolding: "Keeping the Mac awake while agents are working."
        case .whileWorking: "The Mac will stay awake while agents are working."
        case .always: "Keeping the Mac awake while Archipel is open."
        }
        // Idle sleep is the only kind an app can prevent; closing the lid still sleeps the Mac.
        let display = model.stayAwake.keepsDisplayAwake ? "The display stays on too" : "The display can still turn off"
        return state + " " + display + ", and closing the lid still puts the Mac to sleep."
    }
}

/// Menu items only reference their target weakly, so this has to be held by the caller.
private final class ModeMenuTarget: NSObject {
    private let onChoose: (StayAwake.Mode) -> Void

    init(choose: @escaping (StayAwake.Mode) -> Void) {
        onChoose = choose
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? StayAwake.Mode else { return }
        onChoose(mode)
    }
}

#if DEBUG
private func previewStayAwake(_ mode: StayAwake.Mode, holding: Bool) -> some View {
    let model = AppModel.emptyPreview()
    model.stayAwake.showForPreview(mode: mode, isHolding: holding)
    return StayAwakeButton().environment(model)
}

private func previewStayAwakeVariants() -> some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
        GridRow { previewStayAwake(.off, holding: false); Text("Off") }
        GridRow { previewStayAwake(.whileWorking, holding: false); Text("While working, idle") }
        GridRow { previewStayAwake(.whileWorking, holding: true); Text("While working, holding") }
        GridRow { previewStayAwake(.always, holding: true); Text("Always") }
    }
    .font(.system(size: 11))
    .padding()
    .background(.bar)
}

#Preview {
    HStack(spacing: 0) {
        previewStayAwakeVariants()
        previewStayAwakeVariants()
            .environment(\.colorScheme, .dark)
    }
}
#endif
