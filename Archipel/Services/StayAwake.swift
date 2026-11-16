import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac from idle-sleeping so agents can finish long turns while nobody touches the keyboard.
/// By default only system sleep is held off and the display may still turn off; `keepsDisplayAwake`
/// holds the display on too. Closing the lid sleeps the Mac either way.
@Observable
final class StayAwake {
    enum Mode: String, CaseIterable, Identifiable {
        case off, whileWorking, always
        var id: Self { self }

        var title: String {
            switch self {
            case .off: "Off"
            case .whileWorking: "While Agents Are Working"
            case .always: "Always"
            }
        }
    }

    var mode: Mode {
        didSet {
            #if DEBUG
            if isPreview { return }
            #endif
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            update()
        }
    }

    /// Holds a display-sleep assertion instead, which also keeps the system awake.
    var keepsDisplayAwake: Bool {
        didSet {
            #if DEBUG
            if isPreview { return }
            #endif
            guard keepsDisplayAwake != oldValue else { return }
            defaults.set(keepsDisplayAwake, forKey: Self.keepsDisplayAwakeKey)
            // The assertion type is fixed at creation, so a held one has to be swapped.
            release()
            update()
        }
    }

    /// Fed by `AppModel` whenever session activity changes.
    var agentsWorking = false {
        didSet { if agentsWorking != oldValue { update() } }
    }

    private(set) var isHolding = false

    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private let defaults: UserDefaults
    private static let modeKey = "settings.stayAwakeMode"
    private static let keepsDisplayAwakeKey = "settings.stayAwakeKeepsDisplayAwake"
    #if DEBUG
    @ObservationIgnored private var isPreview = false
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(Mode.init) ?? .whileWorking
        keepsDisplayAwake = defaults.bool(forKey: Self.keepsDisplayAwakeKey)
        update()
    }

    // No deinit release: this lives as long as the app, and the system drops a process's
    // assertions when it exits, crashes included.

    private func update() {
        #if DEBUG
        if isPreview { return }
        #endif
        let shouldHold = switch mode {
        case .off: false
        case .whileWorking: agentsWorking
        case .always: true
        }
        shouldHold ? hold() : release()
    }

    private func hold() {
        guard !isHolding else { return }
        let type = keepsDisplayAwake ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        // Shows up in `pmset -g assertions`, so the reason should name the app.
        let reason = keepsDisplayAwake
            ? "Archipel is keeping the display awake for running agents"
            : "Archipel is keeping the Mac awake for running agents"
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        // A failed create leaves nothing to release, so the id is only kept on success. The next
        // update() tries again.
        guard result == kIOReturnSuccess else {
            assertionID = 0
            isHolding = false
            return
        }
        assertionID = id
        isHolding = true
    }

    private func release() {
        guard isHolding else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHolding = false
    }
}

#if DEBUG
extension StayAwake {
    /// Shows a state without writing the setting or taking a real power assertion.
    func showForPreview(mode: Mode, isHolding: Bool) {
        isPreview = true
        self.mode = mode
        self.isHolding = isHolding
    }
}
#endif
