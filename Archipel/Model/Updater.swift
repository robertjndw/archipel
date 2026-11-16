import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle. Every GitHub release ends up in one appcast: stable releases
/// for everyone, prereleases tagged with the beta channel for those who opt in.
@Observable
final class Updater {
    /// Debug builds carry build number 1, so every release looks newer and Sparkle would offer to
    /// replace the build you are working on.
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    private(set) var canCheckForUpdates = false

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
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.receivesBetaUpdates ? ["beta"] : []
    }
}
