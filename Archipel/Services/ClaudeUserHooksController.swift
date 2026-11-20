import AgentKit
import Foundation
import Observation

/// Installs and maintains Archipel's opt-in hook entries in the user's own Claude settings, so a
/// Claude typed by hand into a shell tab reports to the app.
///
/// The entries point at a symlink in the support directory rather than into the app bundle, so
/// moving or updating the app does not leave a stale path in a file the user owns. The link is
/// repointed at launch while the setting is on.
@Observable
final class ClaudeUserHooksController {
    enum State: Equatable {
        case unknown, notInstalled, installed, outdated
        /// Running from a read-only randomized path (a downloaded app opened without being moved),
        /// which would be gone after a relaunch.
        case translocated
        case failed(String)
    }

    private(set) var state: State = .unknown
    /// Where the entries live. Nil until the login shell has been asked for CLAUDE_CONFIG_DIR.
    private(set) var settingsFile: URL?

    @ObservationIgnored private let link: URL
    @ObservationIgnored private let bundledHelper: URL
    @ObservationIgnored private let socketURL: URL
    @ObservationIgnored private let settings: AppSettings
    /// Chains operations so a toggle during the launch refresh can't interleave with it and leave
    /// the file half-written.
    @ObservationIgnored private var lastOperation: Task<Void, Never>?

    init(supportDirectory: URL, bundledHelper: URL, socketURL: URL, settings: AppSettings) {
        link = supportDirectory.appending(path: "bin", directoryHint: .isDirectory).appending(path: "archipel-hook")
        self.bundledHelper = bundledHelper
        self.socketURL = socketURL
        self.settings = settings
        settingsFile = settings.claudeUserHooksFilePath.map { URL(fileURLWithPath: $0) }
    }

    /// Fire and forget. Does nothing while the switch is off, so launches skip the login shell
    /// lookup unless the feature is in use.
    func refreshAtLaunch() {
        enqueue { [self] in
            guard settings.claudeUserHooksEnabled else { return }
            if isTranslocated {
                set(.translocated)
                return
            }
            let (file, isRemembered) = await targetFile()
            let (link, helper, socket) = (link, bundledHelper, socketURL)
            let result = await Task.detached { () -> Result<ClaudeUserHooks.Status, Error> in
                Result {
                    try Self.refreshLink(link, pointingAt: helper)
                    return try ClaudeUserHooks.status(file: file, link: link, socket: socket)
                }
            }.value
            switch result {
            case .failure(let error):
                set(.failed(error.localizedDescription))
            case .success(.notInstalled):
                // Only trust this for the file we wrote to. A guessed path (the login shell timed
                // out) may be the wrong file, and turning the switch off then would leave live
                // entries behind with nothing to remove them.
                if isRemembered {
                    settings.claudeUserHooksEnabled = false
                    settings.claudeUserHooksFilePath = nil
                }
                set(.notInstalled)
            case .success(.installed):
                set(.installed)
            case .success(.outdated):
                await apply(install: true, file: file)
            }
        }
    }

    func setEnabled(_ on: Bool) async {
        await run { [self] in
            if on, isTranslocated {
                settings.claudeUserHooksEnabled = false
                set(.translocated)
                return
            }
            let (file, _) = on ? (await resolveSettingsFile(), false) : await targetFile()
            // Turning on after CLAUDE_CONFIG_DIR changed would otherwise strand the old file's entries.
            let previous = settings.claudeUserHooksFilePath.map { URL(fileURLWithPath: $0) }
            let succeeded = await apply(install: on, file: file, alsoRemoveFrom: on && previous != file ? previous : nil)
            // A failed install leaves nothing behind, so the switch stays off. A failed removal may
            // leave entries in place, but the user asked for off.
            settings.claudeUserHooksEnabled = on && succeeded
        }
    }

    /// Re-reads the file, for when the settings pane appears or the user edited it by hand.
    func reload() async {
        await run { [self] in await refreshState() }
    }

    // MARK: Operations

    private func enqueue(_ body: @escaping () async -> Void) {
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            await body()
        }
    }

    private func run(_ body: @escaping () async -> Void) async {
        enqueue(body)
        await lastOperation?.value
    }

    private var isTranslocated: Bool {
        bundledHelper.path.contains("/AppTranslocation/")
    }

    private func refreshState() async {
        let (file, _) = await targetFile()
        let (link, socket) = (link, socketURL)
        let result = await Task.detached {
            Result { try ClaudeUserHooks.status(file: file, link: link, socket: socket) }
        }.value
        switch result {
        case .success(.notInstalled): set(isTranslocated && settings.claudeUserHooksEnabled ? .translocated : .notInstalled)
        case .success(.installed): set(.installed)
        case .success(.outdated): set(.outdated)
        case .failure(let error): set(.failed(error.localizedDescription))
        }
    }

    /// Returns whether the file ended up as asked.
    @discardableResult
    private func apply(install: Bool, file: URL, alsoRemoveFrom old: URL? = nil) async -> Bool {
        let (link, helper, socket) = (link, bundledHelper, socketURL)
        let result = await Task.detached { () -> Result<ClaudeUserHooks.Status, Error> in
            Result {
                if let old { try? ClaudeUserHooks.uninstall(file: old, link: link) }
                if install {
                    try Self.refreshLink(link, pointingAt: helper)
                    try ClaudeUserHooks.install(file: file, link: link, socket: socket)
                } else {
                    try ClaudeUserHooks.uninstall(file: file, link: link)
                    try? FileManager.default.removeItem(at: link)
                }
                return try ClaudeUserHooks.status(file: file, link: link, socket: socket)
            }
        }.value
        switch result {
        case .success(let status):
            settings.claudeUserHooksFilePath = install ? file.path : nil
            if settingsFile != file { settingsFile = file }
            set(status == .installed ? .installed : status == .outdated ? .outdated : .notInstalled)
            return true
        case .failure(let error):
            set(.failed(error.localizedDescription))
            return false
        }
    }

    private func set(_ new: State) {
        if state != new { state = new }
    }

    /// Prefers the remembered file, since that is where our entries are. Asks the login shell only
    /// when there is none.
    private func targetFile() async -> (file: URL, isRemembered: Bool) {
        if let path = settings.claudeUserHooksFilePath {
            return (URL(fileURLWithPath: path), true)
        }
        return (await resolveSettingsFile(), false)
    }

    /// Claude's config directory is usually exported from an rc file, which an app started from
    /// the Dock never sees. A value is cached for the app's lifetime. Nil is not, since an unset
    /// variable looks the same as a shell that timed out.
    @ObservationIgnored private var configDirectory: String?

    private func resolveSettingsFile() async -> URL {
        if configDirectory == nil {
            // Detached because the lookup blocks on a subprocess and would otherwise run on the
            // main actor, which this class inherits.
            let fromShell = await Task.detached { await LoginEnvironment.resolveVariable("CLAUDE_CONFIG_DIR") }.value
            configDirectory = fromShell
        }
        let file = ClaudeUserHooks.settingsFile(
            configDirectory: configDirectory ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        if settingsFile != file { settingsFile = file }
        return file
    }

    /// Creates or repoints the stable link. Renaming a temporary link over it is atomic, so a
    /// running Claude never finds the helper missing.
    private nonisolated static func refreshLink(_ link: URL, pointingAt helper: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == helper.path { return }

        let temporary = link.deletingLastPathComponent().appending(path: ".archipel-hook-\(UUID().uuidString)")
        try manager.createSymbolicLink(atPath: temporary.path, withDestinationPath: helper.path)
        if rename(temporary.path, link.path) != 0 {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
