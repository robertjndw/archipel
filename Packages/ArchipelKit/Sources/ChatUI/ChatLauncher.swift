import ACPKit
import AgentKit
import Foundation

/// A resolved agent process to start for a chat.
public struct ChatLaunch: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    /// Variables to set on top of the inherited environment. Always holds `PATH`.
    public var environment: [String: String]

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// Why an agent could not be prepared for a chat. Every case reads as a sentence for the user.
public enum ChatLaunchError: Error, Equatable, Sendable, LocalizedError {
    /// The agent runs through its own CLI, and the app did not find it.
    case cliNotInstalled(agentName: String)
    /// The registry has no entry for the agent.
    case notInRegistry(agentName: String)
    /// The registry offers nothing that runs on this Mac (only uvx, or another platform).
    case unsupportedDistribution(agentName: String)
    /// The agent is an npm package and `node` or `npm` is not on the login PATH.
    case nodeMissing(agentName: String)
    /// A command the launch names could not be found on the login PATH.
    case commandNotFound(agentName: String, command: String)
    /// Downloading or installing failed; `reason` is already readable.
    case installFailed(agentName: String, reason: String)
    /// Checking for an update needs the registry itself, and it could not be reached.
    case registryUnreachable

    public var errorDescription: String? {
        switch self {
        case let .cliNotInstalled(agentName):
            "\(agentName) is not installed."
        case let .notInRegistry(agentName):
            "\(agentName) isn't available as a chat right now."
        case let .unsupportedDistribution(agentName):
            "\(agentName) can't run as a chat on this Mac."
        case let .nodeMissing(agentName):
            "Node.js is required to run \(agentName) as a chat."
        case let .commandNotFound(agentName, command):
            "\(agentName) needs \"\(command)\" to run as a chat, but it wasn't found."
        case let .installFailed(agentName, reason):
            "Couldn't install \(agentName). \(reason)"
        case .registryUnreachable:
            "Couldn't reach the registry."
        }
    }
}

/// The result of asking the registry whether a newer adapter exists.
public struct ChatAgentUpdateCheck: Sendable, Equatable {
    /// The newest installed version, nil when none is installed.
    public var installedVersion: String?
    /// The version the registry offers now.
    public var latestVersion: String

    public init(installedVersion: String?, latestVersion: String) {
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
    }

    /// True when something is installed and the registry offers a newer version.
    public var isUpdateAvailable: Bool {
        guard let installedVersion else { return false }
        return ChatLauncher.compareVersions(latestVersion, installedVersion) == .orderedDescending
    }
}

/// The adapter installed for an agent, as Settings describes it.
public struct ChatInstalledAdapter: Sendable, Equatable {
    public var version: String
    public var source: ACPInstalledAgent.Source
    /// False when the registry listed no checksum for the download. Always false for npm
    /// packages, which npm verifies itself, so look at `source` first.
    public var checksumVerified: Bool

    public init(version: String, source: ACPInstalledAgent.Source, checksumVerified: Bool) {
        self.version = version
        self.source = source
        self.checksumVerified = checksumVerified
    }

    /// A downloaded program that could not be checked against the registry.
    public var isUnverifiedDownload: Bool {
        source == .binary && !checksumVerified
    }
}

/// Turns an agent's `ACPSupport` into a process to start, installing its adapter when needed.
///
/// Every input is injected, so tests run it against a file-URL registry and fake tools. Once some
/// version is installed, `resolve` launches the newest installed one without touching the network;
/// updating is an explicit step (`checkForUpdate`, `update`) for a Settings button.
public struct ChatLauncher: Sendable {
    /// What `resolve` and `update` are doing, for a progress display.
    public enum Progress: Sendable, Equatable {
        case checkingRegistry
        /// A binary download, as a fraction from 0 to 1.
        case downloading(fraction: Double)
        /// An npm install, which reports no fraction.
        case installingPackages
        case done
    }

    /// The agent's name as the user knows it, such as "Claude Code"; used in error messages.
    public var agentName: String
    public var support: ACPSupport
    /// Where the agent's own CLI is, as located by the app; nil when it is not installed.
    public var cliPath: URL?
    /// The user's login shell PATH. GUI apps start with a minimal one, and node-based adapters
    /// need the real one to find `node`.
    public var loginPATH: String
    /// Finds a command on `loginPATH`.
    public var locate: @Sendable (String) -> URL?
    public var registry: ACPRegistryStore
    public var installer: ACPInstaller
    public var platform: ACPPlatform

    public init(
        agentName: String,
        support: ACPSupport,
        cliPath: URL?,
        loginPATH: String,
        locate: @escaping @Sendable (String) -> URL?,
        registry: ACPRegistryStore,
        installer: ACPInstaller,
        platform: ACPPlatform = .current
    ) {
        self.agentName = agentName
        self.support = support
        self.cliPath = cliPath
        self.loginPATH = loginPATH
        self.locate = locate
        self.registry = registry
        self.installer = installer
        self.platform = platform
    }

    // MARK: Resolving

    /// Works out what to start, installing the adapter first if no version of it is installed.
    public func resolve(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws(ChatLaunchError) -> ChatLaunch {
        switch support.launch {
        case let .cli(arguments):
            guard let cliPath else { throw .cliNotInstalled(agentName: agentName) }
            return ChatLaunch(executable: cliPath, arguments: arguments, environment: environment(adding: [:]))
        case let .registry(cliExecutableVariable):
            let installed = try await installedOrInstall(progress: progress)
            return try launch(for: installed, cliExecutableVariable: cliExecutableVariable)
        }
    }

    /// The newest installed version of the adapter, nil when none is or the agent runs through its CLI.
    public func installedVersion() async -> String? {
        guard case .registry = support.launch else { return nil }
        return Self.newest(await installer.installedVersions(of: support.registryID))
    }

    /// The newest installed version with how it was installed, nil when none is or the agent
    /// runs through its CLI.
    public func installedAdapter() async -> ChatInstalledAdapter? {
        guard let version = await installedVersion(),
              let record = await installer.installRecord(of: support.registryID, version: version)
        else { return nil }
        return ChatInstalledAdapter(version: version, source: record.source, checksumVerified: record.checksumVerified)
    }

    /// Asks the registry, over the network, which version is current. Nil when the agent runs
    /// through its own CLI, which the user updates themselves.
    public func checkForUpdate() async throws(ChatLaunchError) -> ChatAgentUpdateCheck? {
        guard case .registry = support.launch else { return nil }
        let entry = try entry(in: try await currentIndex())
        return ChatAgentUpdateCheck(installedVersion: await installedVersion(), latestVersion: entry.version)
    }

    /// Installs the registry's current version and removes every other one. Returns the version
    /// now installed. Does nothing for agents that run through their own CLI, and installs
    /// nothing when the registry offers no newer version than the one installed.
    @discardableResult
    public func update(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws(ChatLaunchError) -> String? {
        guard case .registry = support.launch else { return nil }
        progress(.checkingRegistry)
        let entry = try entry(in: try await currentIndex())
        if let installed = await installedVersion(), Self.compareVersions(entry.version, installed) != .orderedDescending {
            await installer.removeOtherVersions(of: support.registryID, keeping: installed)
            progress(.done)
            return installed
        }
        let installed = try await install(entry, version: entry.version, distribution: try distribution(of: entry), progress: progress)
        await installer.removeOtherVersions(of: support.registryID, keeping: installed.version)
        progress(.done)
        return installed.version
    }

    /// The index fresh from the registry. A cached or bundled copy is no answer to "is there
    /// something newer", and could even name an older version than the one installed.
    private func currentIndex() async throws(ChatLaunchError) -> ACPRegistryIndex {
        let result = await registry.index(maxAge: 0)
        guard result.source == .network else { throw .registryUnreachable }
        return result.index
    }

    private func installedOrInstall(progress: @escaping @Sendable (Progress) -> Void) async throws(ChatLaunchError) -> ACPInstalledAgent {
        if let version = await installedVersion(),
           let entry = try? entry(in: await registry.offlineIndex().index),
           let distribution = try? distribution(of: entry),
           let pinned = Self.pin(distribution, from: entry.version, to: version),
           // Already on disk, so the installer returns it without any download or npm run. No
           // progress is passed on: "Installing" must not flash up on every start. A failure
           // here (files deleted by hand, Node.js gone) falls through to a fresh install, which
           // reports the real problem.
           let installed = try? await install(entry, version: version, distribution: pinned, forLaunch: true, progress: { _ in })
        {
            progress(.done)
            return installed
        }
        progress(.checkingRegistry)
        let entry = try entry(in: await registry.index().index)
        let installed = try await install(
            entry, version: entry.version, distribution: try distribution(of: entry), forLaunch: true, progress: progress
        )
        progress(.done)
        return installed
    }

    private func install(
        _ entry: ACPRegistryAgent,
        version: String,
        distribution: ACPDistribution,
        forLaunch: Bool = false,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws(ChatLaunchError) -> ACPInstalledAgent {
        do {
            switch distribution {
            case .binary:
                // Said before the first byte, so the chat shows it is setting up rather than a
                // bare spinner while the connection is made.
                progress(.downloading(fraction: 0))
                return try await installer.install(
                    agentID: support.registryID, version: version, distribution: distribution,
                    allowsFileArchives: registry.isLocal, forLaunch: forLaunch,
                    progress: { fraction in progress(.downloading(fraction: fraction)) }
                )
            case .npx:
                guard let node = locate("node"), let npm = locate("npm") else {
                    throw ChatLaunchError.nodeMissing(agentName: agentName)
                }
                let tools = ACPNodeTools(npm: npm, node: node, path: loginPATH)
                // Reported up front because npm says nothing until it is done.
                progress(.installingPackages)
                return try await installer.installPackage(
                    agentID: support.registryID, version: version, distribution: distribution, tools: tools,
                    forLaunch: forLaunch
                )
            case .uvx:
                throw ChatLaunchError.unsupportedDistribution(agentName: agentName)
            }
        } catch let error as ChatLaunchError {
            throw error
        } catch {
            throw .installFailed(agentName: agentName, reason: error.localizedDescription)
        }
    }

    private func launch(for installed: ACPInstalledAgent, cliExecutableVariable: String?) throws(ChatLaunchError) -> ChatLaunch {
        let executable: URL
        switch installed.launch.command {
        case let .file(url):
            executable = url
        case let .named(name):
            guard let url = locate(name) else { throw .commandNotFound(agentName: agentName, command: name) }
            executable = url
        }
        var extra = installed.launch.environment
        if let cliExecutableVariable, let cliPath {
            extra[cliExecutableVariable] = cliPath.path
        }
        return ChatLaunch(executable: executable, arguments: installed.launch.arguments, environment: environment(adding: extra))
    }

    /// Registry variables first, then the adapter's own, then `PATH`, which nothing may override:
    /// the adapter has to find the same tools the user's shell would.
    private func environment(adding registryEnvironment: [String: String]) -> [String: String] {
        var environment = registryEnvironment
        environment.merge(support.environment) { _, adapter in adapter }
        environment["PATH"] = loginPATH
        return environment
    }

    private func entry(in index: ACPRegistryIndex) throws(ChatLaunchError) -> ACPRegistryAgent {
        guard let entry = index.agent(id: support.registryID) else { throw .notInRegistry(agentName: agentName) }
        return entry
    }

    private func distribution(of entry: ACPRegistryAgent) throws(ChatLaunchError) -> ACPDistribution {
        guard let distribution = entry.distribution(for: platform) else { throw .unsupportedDistribution(agentName: agentName) }
        return distribution
    }

    // MARK: Versions

    /// The distribution as it was for `installed`, when the index describes `listed`.
    ///
    /// A binary's archive address only matters for downloading, which an existing install skips,
    /// so it passes as is. An npm spec names its version, and the installer only recognises an
    /// install made from the same spec, so the version in it is swapped; when the spec does not
    /// follow the registry's version there is no telling what it was, and nil sends the caller to
    /// a fresh install instead.
    static func pin(_ distribution: ACPDistribution, from listed: String, to installed: String) -> ACPDistribution? {
        guard listed != installed else { return distribution }
        switch distribution {
        case .binary:
            return distribution
        case let .npx(package, args, env):
            let suffix = "@\(listed)"
            guard package.hasSuffix(suffix), package.count > suffix.count else { return nil }
            return .npx(package: String(package.dropLast(suffix.count)) + "@\(installed)", args: args, env: env)
        case .uvx:
            return nil
        }
    }

    /// The highest version by numeric comparison; `installedVersions(of:)` sorts by name, which
    /// puts 0.9.0 after 0.110.0.
    static func newest(_ versions: [String]) -> String? {
        versions.max { compareVersions($0, $1) == .orderedAscending }
    }

    /// Compares dotted versions number by number. A pre-release suffix (`1.0.0-beta`) sorts before
    /// the release; parts that are not numbers compare as text.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func split(_ version: String) -> (core: [Substring], prerelease: Substring?) {
            let trimmed = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
            let withoutBuild = trimmed.split(separator: "+", maxSplits: 1).first ?? trimmed
            let parts = withoutBuild.split(separator: "-", maxSplits: 1)
            return (parts.first?.split(separator: ".") ?? [], parts.count > 1 ? parts[1] : nil)
        }
        let left = split(lhs)
        let right = split(rhs)
        for index in 0..<max(left.core.count, right.core.count) {
            let a = index < left.core.count ? left.core[index] : "0"
            let b = index < right.core.count ? right.core[index] : "0"
            if let x = Int(a), let y = Int(b) {
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            } else if a != b {
                return a < b ? .orderedAscending : .orderedDescending
            }
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        }
    }
}
