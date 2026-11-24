import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle. Every GitHub release ends up in one appcast: stable releases
/// for everyone, prereleases tagged with the beta channel for those who opt in.
@Observable
final class Updater {
    /// Only builds from the release pipeline get a real build number. Debug builds and copies built
    /// from source keep the placeholder 1, so every release would look newer and Sparkle would
    /// offer to replace the build you made yourself.
    static let isEnabled: Bool = {
        #if DEBUG
        return false
        #else
        return !isSourceBuild
        #endif
    }()

    /// True for a build that did not come from the release pipeline, see docs/releasing.md. Debug
    /// builds have the placeholder too, so check `isDebugBuild` first when telling the two apart.
    static let isSourceBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) == "1"

    static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    private(set) var canCheckForUpdates = false
    private(set) var lastCheckDate: Date?

    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    var receivesBetaUpdates: Bool {
        didSet {
            UserDefaults.standard.set(receivesBetaUpdates, forKey: UpdaterDelegate.betaKey)
            // Sparkle only reads the allowed channels when it checks, so start the next check now
            // instead of a day from now.
            if Self.isEnabled { controller.updater.resetUpdateCycleAfterShortDelay() }
        }
    }

    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: delegate, userDriverDelegate: nil)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        receivesBetaUpdates = UpdaterDelegate.receivesBetaUpdates
        // Written once the choice is derived from the version, or a stable update would move a
        // beta tester to the stable channel on the next launch. Assigning in init skips didSet.
        if UserDefaults.standard.object(forKey: UpdaterDelegate.betaKey) == nil, receivesBetaUpdates {
            UserDefaults.standard.set(true, forKey: UpdaterDelegate.betaKey)
        }
        lastCheckDate = controller.updater.lastUpdateCheckDate
        // Background checks move the date too, so read it whenever a cycle ends rather than only
        // after a check from the button.
        delegate.didFinishUpdateCycle = { [weak self] in
            guard let self else { return }
            lastCheckDate = controller.updater.lastUpdateCheckDate
        }
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // KVO closures are always nonisolated, but SPUUpdater only ever changes this on the
            // main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Kept apart from `Updater` and nonisolated because Sparkle calls it as a plain Objective-C delegate.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated static let betaKey = "settings.receivesBetaUpdates"

    var didFinishUpdateCycle: (() -> Void)?

    /// Someone running a beta got it from a prerelease DMG, so they stay on the beta channel until
    /// they turn it off. Everyone else starts on stable.
    nonisolated static var receivesBetaUpdates: Bool {
        if UserDefaults.standard.object(forKey: betaKey) != nil {
            return UserDefaults.standard.bool(forKey: betaKey)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.contains("-")
    }

    /// Items without a channel are stable and always allowed. Beta users still move on to a stable
    /// release once it is newer than their beta.
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // Sparkle calls its delegate on the main thread.
        MainActor.assumeIsolated { didFinishUpdateCycle?() }
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.receivesBetaUpdates ? ["beta"] : []
    }
}
