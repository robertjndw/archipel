import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac from idle-sleeping so agents can finish long turns while nobody touches the keyboard.
/// The display may still sleep; only system sleep is held off.
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

    /// Fed by `AppModel` whenever session activity changes.
    var agentsWorking = false {
        didSet { if agentsWorking != oldValue { update() } }
    }

    private(set) var isHolding = false

    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private let defaults: UserDefaults
    private static let modeKey = "settings.stayAwakeMode"
    #if DEBUG
    @ObservationIgnored private var isPreview = false
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(Mode.init) ?? .whileWorking
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
        // Shows up in `pmset -g assertions`, so the reason should name the app.
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Archipel is keeping the Mac awake for running agents" as CFString,
            &assertionID
        )
        isHolding = result == kIOReturnSuccess
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
