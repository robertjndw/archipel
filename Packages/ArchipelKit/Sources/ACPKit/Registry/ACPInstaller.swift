import CryptoKit
import Foundation
import Synchronization

/// What went wrong while installing an agent, phrased for the person who sees it.
public enum ACPInstallError: Error, Equatable, LocalizedError {
    case notBinaryDistribution
    case notPackageDistribution
    case invalidPackageSpec(String)
    case npmFailed(stderr: String)
    case noRunnableBin(package: String, reason: String)
    case toolMissing(String)
    case invalidIdentifier(String)
    case invalidCommand(String)
    case noNetwork
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case unsupportedArchive(String)
    case unpackFailed(tool: String, stderr: String)
    case unsafeArchive
    case executableMissing(String)
    case executableOutsideInstall(String)
    case installFailed(String)
    /// npm ran longer than its time limit and was stopped.
    case npmTimedOut(minutes: Int)
    /// The registry points a download at a file on this Mac, which only a local test registry may.
    case localArchiveRejected

    public var errorDescription: String? {
        switch self {
        case .notBinaryDistribution:
            "This agent is not distributed as a downloadable program."
        case .notPackageDistribution:
            "This agent is not distributed as an npm package."
        case .invalidPackageSpec(let spec):
            "The registry's package \"\(spec)\" is not a plain npm package with an exact version, so it was rejected."
        case .npmFailed(let stderr):
            "npm could not install the agent: \(stderr.isEmpty ? "no details" : stderr)"
        case .noRunnableBin(let package, let reason):
            "The package \"\(package)\" has no program Archipel can run: \(reason)"
        case .toolMissing(let path):
            "\"\(path)\" is not an executable program."
        case .invalidIdentifier(let value):
            "\"\(value)\" is not a valid agent id or version."
        case .invalidCommand(let cmd):
            "The registry's launch command \"\(cmd)\" points outside the install folder, so it was rejected."
        case .noNetwork:
            "Could not reach the download server. Check your internet connection and try again."
        case .downloadFailed(let reason):
            "The download failed: \(reason)"
        case .checksumMismatch(let expected, let actual):
            "The download does not match the registry checksum (expected \(expected), got \(actual)), so it was discarded."
        case .unsupportedArchive(let name):
            "The archive \"\(name)\" is in a format Archipel cannot unpack."
        case .unpackFailed(let tool, let stderr):
            "Unpacking failed (\(tool)): \(stderr.isEmpty ? "no details" : stderr)"
        case .unsafeArchive:
            "The archive contains files outside its own folder, so it was rejected."
        case .executableMissing(let cmd):
            "The download does not contain the expected program \"\(cmd)\"."
        case .executableOutsideInstall(let cmd):
            "The program \"\(cmd)\" resolves to a location outside the install folder, so it was rejected."
        case .installFailed(let reason):
            "The install could not be completed: \(reason)"
        case .npmTimedOut(let minutes):
            "npm didn't finish within \(minutes) minutes, so it was stopped. Check your internet connection and try again."
        case .localArchiveRejected:
            "The registry lists a download on this Mac instead of on the web, so it was rejected."
        }
    }
}

/// A finished install, ready to launch.
public struct ACPInstalledAgent: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case binary
        /// Installed with npm. Such installs report no fractional progress, only completion.
        case npmPackage
    }

    public var launch: ACPLaunchSpec
    public var installDirectory: URL
    public var version: String
    public var source: Source
    /// False when the registry offered no checksum, so the download is unverified. Always false
    /// for npm packages: npm checks the integrity of what it fetches, but not against a registry hash.
    public var checksumVerified: Bool
}

/// The Node tooling an npm package install needs, located by the caller on the user's login PATH.
public struct ACPNodeTools: Sendable, Equatable {
    public var npm: URL
    public var node: URL
    /// Given to npm as `PATH`; npm's own launcher looks `node` up there.
    public var path: String

    public init(npm: URL, node: URL, path: String) {
        self.npm = npm
        self.node = node
        self.path = path
    }
}

/// Installs agent binaries and npm packages into `<root>/<agentID>/<version>/`.
public actor ACPInstaller {
    public typealias ProgressHandler = @Sendable (Double) async -> Void

    private struct Marker: Codable {
        var checksumVerified: Bool
        /// The npm package spec of a package install; nil for binaries, so a version directory
        /// left by one kind is never mistaken for the other.
        var package: String?
    }

    private struct InFlight {
        /// Tells this install apart from a later one for the same version, once it was abandoned.
        let id: UUID
        var task: Task<ACPInstalledAgent, any Error>
        var observers: [UUID: ProgressHandler] = [:]
        var waiters = 0
    }

    /// What `installRecord` reports about a finished install.
    public struct Record: Sendable, Equatable {
        public var source: ACPInstalledAgent.Source
        public var checksumVerified: Bool
    }

    static let markerName = ".archipel-install-complete"

    private let root: URL
    private let session: URLSession
    private let onDownload: @Sendable (URL) async -> Void
    private let npmTimeout: Duration
    private var inFlight: [String: InFlight] = [:]
    /// Versions handed out for a launch in this run, by agent. A chat may be starting or running
    /// one of them, so `removeOtherVersions` leaves them for a later cleanup.
    private var launchedVersions: [String: Set<String>] = [:]

    /// `npmTimeout` is generous because a slow connection can take minutes for a large package.
    /// `onDownload` runs right before each download starts; tests use it to count downloads and to
    /// hold them open long enough for concurrent installs to overlap.
    public init(root: URL, npmTimeout: Duration = .seconds(600), onDownload: @escaping @Sendable (URL) async -> Void = { _ in }) {
        self.root = root
        self.onDownload = onDownload
        self.npmTimeout = npmTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        session = URLSession(configuration: configuration)
    }

    // MARK: Installed state

    /// Versions with a completed install, sorted by name.
    public func installedVersions(of agentID: String) -> [String] {
        guard isSafeComponent(agentID) else { return [] }
        let directory = root.appendingPathComponent(agentID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .filter { readMarker(in: directory.appendingPathComponent($0)) != nil }
            .sorted()
    }

    /// Deletes every version of `agentID` except `version`, including half-finished leftovers.
    /// Versions installed or returned with `forLaunch` in this run stay, since a chat may be using
    /// one; a later update removes them.
    public func removeOtherVersions(of agentID: String, keeping version: String) {
        guard isSafeComponent(agentID) else { return }
        let directory = root.appendingPathComponent(agentID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let launched = launchedVersions[agentID] ?? []
        for name in names where name != version && !name.hasPrefix(".") && !launched.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// How a completed install of `version` came about, nil when there is none.
    public func installRecord(of agentID: String, version: String) -> Record? {
        guard isSafeComponent(agentID), isSafeComponent(version),
              let marker = readMarker(in: root.appendingPathComponent(agentID).appendingPathComponent(version))
        else { return nil }
        return Record(source: marker.package == nil ? .binary : .npmPackage, checksumVerified: marker.checksumVerified)
    }

    private func noteLaunch(of agentID: String, version: String) {
        launchedVersions[agentID, default: []].insert(version)
    }

    // MARK: Install

    /// Installs a `.binary` distribution, or returns the existing install without any network.
    /// Concurrent calls for the same agent and version share one download and all see its progress.
    ///
    /// `allowsFileArchives` lets the archive be a `file://` URL. Only for an index that was itself
    /// read from a file, as test registries are; a real registry pointing at a file on this Mac is
    /// refused. `forLaunch` keeps this version through `removeOtherVersions` for the rest of the
    /// run, because a chat is about to start it.
    public func install(
        agentID: String,
        version: String,
        distribution: ACPDistribution,
        allowsFileArchives: Bool = false,
        forLaunch: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> ACPInstalledAgent {
        guard case .binary(let archive, let cmd, let args, let env, let sha256) = distribution else {
            throw ACPInstallError.notBinaryDistribution
        }
        guard isSafeComponent(agentID) else { throw ACPInstallError.invalidIdentifier(agentID) }
        guard isSafeComponent(version) else { throw ACPInstallError.invalidIdentifier(version) }
        try validate(cmd: cmd)

        let directory = root.appendingPathComponent(agentID).appendingPathComponent(version)
        if let existing = installed(at: directory, version: version, cmd: cmd, args: args, env: env) {
            if forLaunch { noteLaunch(of: agentID, version: version) }
            return existing
        }

        // The program is run as the user, so it must not come over a connection anyone on the
        // network could rewrite. A checksum does not cover this: the registry may not offer one.
        if archive.isFileURL {
            guard allowsFileArchives else { throw ACPInstallError.localArchiveRejected }
        } else if archive.scheme != "https" {
            throw ACPInstallError.downloadFailed("the registry lists an insecure download address")
        }

        let installed = try await coalesced(key: "\(agentID)/\(version)", progress: progress) { report in
            try await self.doInstall(
                agentID: agentID, version: version, archive: archive, cmd: cmd, args: args,
                env: env, sha256: sha256, progress: report
            )
        }
        if forLaunch { noteLaunch(of: agentID, version: version) }
        return installed
    }

    /// Runs `work` once for any number of callers asking for the same `key` at the same time.
    ///
    /// A caller whose task is cancelled stops waiting at once and gets `CancellationError`; the
    /// others still get the result. Only when the last caller is gone is the install itself
    /// cancelled, which stops its download or its npm process, and a later caller starts afresh.
    private func coalesced(
        key: String,
        progress: ProgressHandler?,
        work: @escaping @Sendable (@escaping ProgressHandler) async throws -> ACPInstalledAgent
    ) async throws -> ACPInstalledAgent {
        let observerID = UUID()
        if inFlight[key] == nil {
            let id = UUID()
            let task = Task {
                try await self.perform(key: key, id: id, work: work)
            }
            inFlight[key] = InFlight(id: id, task: task)
        }
        guard var flight = inFlight[key] else { throw ACPInstallError.installFailed("install vanished") }
        flight.waiters += 1
        if let progress { flight.observers[observerID] = progress }
        inFlight[key] = flight
        defer { leave(key: key, id: flight.id, observer: observerID) }
        return try await waitCancellably(for: flight.task)
    }

    /// How many callers wait on the install of this version, for tests.
    func waiterCount(agentID: String, version: String) -> Int {
        inFlight["\(agentID)/\(version)"]?.waiters ?? 0
    }

    private func leave(key: String, id: UUID, observer: UUID) {
        // Gone or replaced: the install finished, and `perform` already let go of it.
        guard var flight = inFlight[key], flight.id == id else { return }
        flight.observers[observer] = nil
        flight.waiters -= 1
        if flight.waiters > 0 {
            inFlight[key] = flight
        } else {
            flight.task.cancel()
            inFlight[key] = nil
        }
    }

    private func perform(
        key: String,
        id: UUID,
        work: @Sendable (@escaping ProgressHandler) async throws -> ACPInstalledAgent
    ) async throws -> ACPInstalledAgent {
        defer { if inFlight[key]?.id == id { inFlight[key] = nil } }
        let report: ProgressHandler = { [weak self] fraction in
            await self?.broadcast(key: key, fraction)
        }
        return try await work(report)
    }

    private func broadcast(key: String, _ fraction: Double) async {
        for observer in inFlight[key]?.observers.values ?? [:].values {
            await observer(fraction)
        }
    }

    private func doInstall(
        agentID: String, version: String, archive: URL, cmd: String, args: [String],
        env: [String: String], sha256: String?, progress: @escaping ProgressHandler
    ) async throws -> ACPInstalledAgent {
        let fileManager = FileManager.default
        let agentDirectory = root.appendingPathComponent(agentID)
        let finalDirectory = agentDirectory.appendingPathComponent(version)
        sweepStaleStaging(in: agentDirectory)

        // Dot-prefixed so listings and cleanup never mistake it for a version.
        let staging = agentDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw ACPInstallError.installFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: staging) }

        let downloaded = staging.appendingPathComponent("download")
        await onDownload(archive)
        try await download(archive, to: downloaded, progress: progress)

        var verified = false
        if let expected = sha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !expected.isEmpty {
            let actual = try Self.sha256Hex(of: downloaded)
            guard actual == expected else {
                throw ACPInstallError.checksumMismatch(expected: expected, actual: actual)
            }
            verified = true
        }

        // The archive is unpacked one level below `unpack` so that an entry climbing out of
        // `content` lands in `unpack`, where the check below can see it.
        let unpack = staging.appendingPathComponent("unpack")
        let content = unpack.appendingPathComponent("content")
        try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
        try await unpackArchive(downloaded, named: archive.lastPathComponent, cmd: cmd, into: content)

        let siblings = (try? fileManager.contentsOfDirectory(atPath: unpack.path)) ?? []
        guard siblings == ["content"] else { throw ACPInstallError.unsafeArchive }
        let stagedExecutable = try resolveExecutable(in: content, cmd: cmd)
        try makeExecutable(stagedExecutable)
        await clearQuarantine(content)

        try commit(content, to: finalDirectory, marker: Marker(checksumVerified: verified, package: nil))

        guard let result = installed(at: finalDirectory, version: version, cmd: cmd, args: args, env: env) else {
            throw ACPInstallError.executableMissing(cmd)
        }
        await progress(1)
        return result
    }

    // MARK: Package install

    /// Installs an `.npx` distribution into a private npm prefix, or returns the existing install
    /// without starting any process. The agent then runs as `node <bin>`, which starts in a fraction
    /// of the time a cold `npx -y` needs to download and unpack the package.
    ///
    /// npm gives no usable fractional progress, so `progress` is called exactly once, with 1, when
    /// the install has finished. Concurrent calls for the same agent and version share one install.
    public func installPackage(
        agentID: String,
        version: String,
        distribution: ACPDistribution,
        tools: ACPNodeTools,
        forLaunch: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> ACPInstalledAgent {
        guard case .npx(let package, let args, let env) = distribution else {
            throw ACPInstallError.notPackageDistribution
        }
        guard isSafeComponent(agentID) else { throw ACPInstallError.invalidIdentifier(agentID) }
        guard isSafeComponent(version) else { throw ACPInstallError.invalidIdentifier(version) }
        guard let name = Self.packageName(ofSpec: package) else { throw ACPInstallError.invalidPackageSpec(package) }

        // Explicit directory flag: URLs compare unequal otherwise, depending on whether the path existed yet.
        let directory = root.appendingPathComponent(agentID).appendingPathComponent(version, isDirectory: true)
        if let existing = installedPackage(
            at: directory, version: version, package: package, name: name, args: args, env: env, node: tools.node
        ) {
            if forLaunch { noteLaunch(of: agentID, version: version) }
            return existing
        }
        for tool in [tools.npm, tools.node] where !FileManager.default.isExecutableFile(atPath: tool.path) {
            throw ACPInstallError.toolMissing(tool.path)
        }

        let timeout = npmTimeout
        let installed = try await coalesced(key: "\(agentID)/\(version)", progress: progress) { report in
            try await self.doInstallPackage(
                agentID: agentID, version: version, package: package, name: name,
                args: args, env: env, tools: tools, timeout: timeout, progress: report
            )
        }
        if forLaunch { noteLaunch(of: agentID, version: version) }
        return installed
    }

    /// The package name of an exact, registry-hosted npm spec such as `@scope/name@1.2.3`, or nil
    /// for anything else. Deliberately narrow: the spec is handed to npm, and a tampered registry
    /// must not be able to smuggle in a URL, a path, a git source, a version range or a flag.
    static func packageName(ofSpec spec: String) -> String? {
        let name = "[A-Za-z0-9][A-Za-z0-9._~-]*"
        let pattern = "^((?:@\(name)/)?\(name))@[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\\+[0-9A-Za-z.-]+)?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)),
              let range = Range(match.range(at: 1), in: spec)
        else { return nil }
        return String(spec[range])
    }

    private func doInstallPackage(
        agentID: String, version: String, package: String, name: String,
        args: [String], env: [String: String], tools: ACPNodeTools, timeout: Duration, progress: ProgressHandler
    ) async throws -> ACPInstalledAgent {
        let fileManager = FileManager.default
        let agentDirectory = root.appendingPathComponent(agentID)
        let finalDirectory = agentDirectory.appendingPathComponent(version, isDirectory: true)
        sweepStaleStaging(in: agentDirectory)

        let staging = agentDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
        let prefix = staging.appendingPathComponent("prefix")
        do {
            try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        } catch {
            throw ACPInstallError.installFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: staging) }

        // npm's launcher finds `node` through PATH. The rest of the environment is kept because
        // npm needs HOME for its cache and breaks without it.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = tools.path
        let result: ProcessResult
        do {
            result = try await Self.runProcess(
                tools.npm.path,
                ["install", "--prefix", prefix.path, "--no-audit", "--no-fund", "--loglevel=error", package],
                environment: environment,
                timeout: timeout
            )
        } catch is ProcessTimedOut {
            throw ACPInstallError.npmTimedOut(minutes: max(1, Int(timeout.components.seconds / 60)))
        } catch {
            throw ACPInstallError.npmFailed(stderr: error.localizedDescription)
        }
        guard result.status == 0 else { throw ACPInstallError.npmFailed(stderr: result.stderr) }

        // Checked before the move so a package that cannot run never reaches the install directory.
        _ = try resolveBin(in: prefix, name: name)

        // Moving the whole prefix keeps `node_modules/.bin` valid because npm links relatively.
        try commit(prefix, to: finalDirectory, marker: Marker(checksumVerified: false, package: package))

        guard let result = installedPackage(
            at: finalDirectory, version: version, package: package, name: name, args: args, env: env, node: tools.node
        ) else {
            try? fileManager.removeItem(at: finalDirectory)
            throw ACPInstallError.noRunnableBin(package: name, reason: "the installed files could not be read back")
        }
        await progress(1)
        return result
    }

    private func installedPackage(
        at directory: URL, version: String, package: String, name: String,
        args: [String], env: [String: String], node: URL
    ) -> ACPInstalledAgent? {
        guard let marker = readMarker(in: directory), marker.package == package,
              let bin = try? resolveBin(in: directory, name: name)
        else { return nil }
        return ACPInstalledAgent(
            launch: ACPLaunchSpec(command: .file(node), arguments: [bin.path] + args, environment: env),
            installDirectory: directory,
            version: version,
            source: .npmPackage,
            checksumVerified: false
        )
    }

    /// The JavaScript entry point of the package installed under `prefix`, symlinks resolved.
    private func resolveBin(in prefix: URL, name: String) throws -> URL {
        let packageDirectory = prefix.appendingPathComponent("node_modules").appendingPathComponent(name)
        guard let data = try? Data(contentsOf: packageDirectory.appendingPathComponent("package.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw ACPInstallError.noRunnableBin(package: name, reason: "its package.json is missing or unreadable") }

        let relative: String
        switch manifest["bin"] {
        case let single as String:
            relative = single
        case let table as [String: String]:
            let unscoped = String(name.split(separator: "/").last ?? Substring(name))
            if let match = table[unscoped] {
                relative = match
            } else if table.count == 1, let only = table.values.first {
                relative = only
            } else if table.isEmpty {
                throw ACPInstallError.noRunnableBin(package: name, reason: "it declares no bin")
            } else {
                let keys = table.keys.sorted().joined(separator: ", ")
                throw ACPInstallError.noRunnableBin(package: name, reason: "it declares several bins (\(keys)) and none is named \"\(unscoped)\"")
            }
        default:
            throw ACPInstallError.noRunnableBin(package: name, reason: "it declares no bin")
        }
        guard !relative.isEmpty, !relative.contains("\0") else {
            throw ACPInstallError.noRunnableBin(package: name, reason: "its bin path is empty")
        }

        let candidate = packageDirectory.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw ACPInstallError.noRunnableBin(package: name, reason: "its bin \"\(relative)\" does not exist")
        }
        // The bin is data from the package, so containment is judged on resolved paths.
        let resolved = candidate.resolvingSymlinksInPath()
        let base = prefix.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(base + "/") else { throw ACPInstallError.executableOutsideInstall(relative) }
        return resolved
    }

    /// Moves a staged install into place and marks it complete.
    private func commit(_ content: URL, to finalDirectory: URL, marker: Marker) throws {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: finalDirectory.path) {
                try fileManager.removeItem(at: finalDirectory)
            }
            try fileManager.moveItem(at: content, to: finalDirectory)
            // Written last: a crash before this line leaves a directory that never counts as installed.
            let data = try JSONEncoder().encode(marker)
            try data.write(to: finalDirectory.appendingPathComponent(Self.markerName), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: finalDirectory)
            throw ACPInstallError.installFailed(error.localizedDescription)
        }
    }

    // MARK: Checks

    private func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.hasPrefix(".")
            && !value.contains("/") && !value.contains("\0")
    }

    /// Rejects absolute paths and any `..` segment up front; the symlink-resolved check after
    /// unpacking covers what a lexical test cannot.
    private func validate(cmd: String) throws {
        let parts = cmd.split(separator: "/", omittingEmptySubsequences: false)
        if cmd.isEmpty || cmd.hasPrefix("/") || cmd.hasPrefix("~") || cmd.contains("\0") || parts.contains("..") {
            throw ACPInstallError.invalidCommand(cmd)
        }
    }

    private func readMarker(in directory: URL) -> Marker? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.markerName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private func installed(
        at directory: URL, version: String, cmd: String, args: [String], env: [String: String]
    ) -> ACPInstalledAgent? {
        guard let marker = readMarker(in: directory), marker.package == nil,
              let executable = try? resolveExecutable(in: directory, cmd: cmd),
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { return nil }
        return ACPInstalledAgent(
            launch: ACPLaunchSpec(command: .file(executable), arguments: args, environment: env),
            installDirectory: directory,
            version: version,
            source: .binary,
            checksumVerified: marker.checksumVerified
        )
    }

    private func resolveExecutable(in directory: URL, cmd: String) throws -> URL {
        try validate(cmd: cmd)
        let candidate = directory.appendingPathComponent(cmd)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw ACPInstallError.executableMissing(cmd)
        }
        // A symlink inside the archive can aim anywhere, so containment is judged on resolved paths.
        let resolved = candidate.resolvingSymlinksInPath()
        let base = directory.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(base + "/") else { throw ACPInstallError.executableOutsideInstall(cmd) }
        return resolved
    }

    private func makeExecutable(_ url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let current = (attributes?[.posixPermissions] as? Int) ?? 0o644
        do {
            try FileManager.default.setAttributes([.posixPermissions: current | 0o755], ofItemAtPath: url.path)
        } catch {
            throw ACPInstallError.installFailed(error.localizedDescription)
        }
    }

    /// Staging directories survive only if the app died mid-install; anything over an hour old is
    /// garbage. The age limit keeps this from deleting a sibling version's live download.
    private func sweepStaleStaging(in agentDirectory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: agentDirectory.path)) ?? []
        for name in names where name.hasPrefix(".staging-") {
            let url = agentDirectory.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, Date().timeIntervalSince(modified) > 3600 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Download

    private func download(_ url: URL, to destination: URL, progress: @escaping ProgressHandler) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Double.self)
        let pump = Task {
            for await fraction in stream { await progress(fraction) }
        }
        let delegate = DownloadProgress(continuation: continuation)
        do {
            let (temporary, response) = try await session.download(from: url, delegate: delegate)
            continuation.finish()
            await pump.value
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temporary)
                throw ACPInstallError.downloadFailed("the server answered with status \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as ACPInstallError {
            continuation.finish()
            throw error
        } catch let error as URLError {
            continuation.finish()
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff:
                throw ACPInstallError.noNetwork
            default:
                throw ACPInstallError.downloadFailed(error.localizedDescription)
            }
        } catch {
            continuation.finish()
            throw ACPInstallError.downloadFailed(error.localizedDescription)
        }
    }

    private static func sha256Hex(of file: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw ACPInstallError.installFailed(error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Unpack

    private func unpackArchive(_ file: URL, named name: String, cmd: String, into content: URL) async throws {
        let lowered = name.lowercased()
        if lowered.hasSuffix(".zip") {
            try await Self.run("/usr/bin/ditto", ["-x", "-k", file.path, content.path])
        } else if [".tar.gz", ".tgz", ".tar.bz2", ".tbz2"].contains(where: lowered.hasSuffix) {
            try await Self.run("/usr/bin/tar", ["-xf", file.path, "-C", content.path])
        } else if lowered.hasSuffix(".tar") || lowered.hasSuffix(".tar.xz") || lowered.hasSuffix(".7z")
            || lowered.hasSuffix(".dmg") || lowered.hasSuffix(".pkg") {
            throw ACPInstallError.unsupportedArchive(name)
        } else {
            // A bare executable: it becomes whatever `cmd` says it is called.
            let target = content.appendingPathComponent(cmd)
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: file, to: target)
            } catch {
                throw ACPInstallError.installFailed(error.localizedDescription)
            }
        }
    }

    private func clearQuarantine(_ directory: URL) async {
        // Absent attribute makes xattr exit non-zero; that is the normal case.
        _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", directory.path])
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let result: ProcessResult
        do {
            result = try await runProcess(tool, arguments, environment: nil)
        } catch {
            throw ACPInstallError.unpackFailed(tool: tool, stderr: error.localizedDescription)
        }
        guard result.status == 0 else { throw ACPInstallError.unpackFailed(tool: tool, stderr: result.stderr) }
    }

    private struct ProcessResult {
        var status: Int32
        var stderr: String
    }

    private struct ProcessTimedOut: Error {}

    /// Runs a tool to completion, discarding stdout. A nil `environment` inherits the app's.
    ///
    /// Cancelling the calling task terminates the tool, and so does running past `timeout`, which
    /// throws `ProcessTimedOut`.
    private static func runProcess(
        _ tool: String, _ arguments: [String], environment: [String: String]?, timeout: Duration? = nil
    ) async throws -> ProcessResult {
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("acp-tool-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: errorFile.path, contents: nil),
              let errorHandle = try? FileHandle(forWritingTo: errorFile)
        else { throw ACPInstallError.installFailed("could not capture output") }
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorFile)
        }
        // stderr goes to a file rather than a pipe so a chatty tool can never block on a full buffer.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        let control = ProcessControl(process)
        let timer = timeout.map { timeout in
            Task {
                try await Task.sleep(for: timeout)
                control.stop(timedOut: true)
            }
        }
        defer { timer?.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try control.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            control.stop(timedOut: false)
        }
        if control.didTimeOut { throw ProcessTimedOut() }
        try Task.checkCancellation()
        let stderr = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        return ProcessResult(status: process.terminationStatus, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Starts a process and stops it from any thread, without ever terminating one that was never
/// launched, which `Process` answers with an exception.
private final class ProcessControl: Sendable {
    private struct State {
        var isLaunched = false
        var isStopped = false
        var didTimeOut = false
    }

    private let process: Process
    private let state = Mutex(State())

    init(_ process: Process) {
        self.process = process
    }

    var didTimeOut: Bool { state.withLock { $0.didTimeOut } }

    /// Throws `CancellationError` when `stop` came first.
    func run() throws {
        try state.withLock { state in
            guard !state.isStopped else { throw CancellationError() }
            try process.run()
            state.isLaunched = true
        }
    }

    func stop(timedOut: Bool) {
        state.withLock { state in
            guard !state.isStopped else { return }
            state.isStopped = true
            state.didTimeOut = timedOut
            if state.isLaunched, process.isRunning { process.terminate() }
        }
    }
}

/// Waits for `task` the way `task.value` does, except that cancelling the waiting task ends the
/// wait at once with `CancellationError`. `task` itself is not cancelled and runs on.
func waitCancellably<Value: Sendable>(for task: Task<Value, any Error>) async throws -> Value {
    let gate = WaitGate<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard gate.install(continuation) else {
                continuation.resume(throwing: CancellationError())
                return
            }
            Task { gate.resume(with: await task.result) }
        }
    } onCancel: {
        gate.cancel()
    }
}

/// Resumes one continuation exactly once: with the result, or with cancellation, whichever is first.
private final class WaitGate<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var isCancelled = false
    }

    private let state = Mutex(State())

    /// False when the wait was cancelled before it began.
    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        state.withLock { state in
            guard !state.isCancelled else { return false }
            state.continuation = continuation
            return true
        }
    }

    func resume(with result: Result<Value, any Error>) {
        take()?.resume(with: result)
    }

    func cancel() {
        let continuation = state.withLock { state in
            state.isCancelled = true
            return state.continuation.take()
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func take() -> CheckedContinuation<Value, any Error>? {
        state.withLock { $0.continuation.take() }
    }
}

/// Forwards the progress of one download as fractions. Silent when the size is unknown.
///
/// It watches the task's `Progress` rather than implementing the download delegate's byte
/// callback: a delegate handed to the async download API only gets task-level callbacks, so that
/// byte callback never runs and a 200 MB download would show no progress at all.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let continuation: AsyncStream<Double>.Continuation
    private let observation = Mutex<NSKeyValueObservation?>(nil)

    init(continuation: AsyncStream<Double>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let continuation = continuation
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            // An unknown length reports a total of zero or less and a fraction that means nothing.
            guard progress.totalUnitCount > 0 else { return }
            continuation.yield(min(1, max(0, progress.fractionCompleted)))
        }
        self.observation.withLock { $0 = observation }
    }
}
