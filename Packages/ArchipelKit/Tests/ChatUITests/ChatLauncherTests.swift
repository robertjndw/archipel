import ACPKit
import AgentKit
@testable import ChatUI
import CryptoKit
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ChatLauncherTests {
    private static let loginPATH = "/opt/homebrew/bin:/usr/bin:/bin"

    /// A temp directory with a registry served from a file, an install root and fake tools.
    private struct Sandbox {
        let directory: URL
        var source: URL { directory.appendingPathComponent("registry.json") }
        var cache: URL { directory.appendingPathComponent("cache") }
        var root: URL { directory.appendingPathComponent("agents") }
        var tools: URL { directory.appendingPathComponent("tools") }
        var npmLog: URL { directory.appendingPathComponent("npm.log") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatui-launcher-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        func writeRegistry(_ agents: String) throws {
            try Data(#"{"version":"1.0.0","agents":[\#(agents)],"extensions":[]}"#.utf8).write(to: source)
        }

        /// A zip holding `./agent`, a script that prints `output`. Returns its file URL and sha256.
        func archive(version: String) throws -> (url: URL, sha256: String) {
            let tree = directory.appendingPathComponent("tree-\(version)")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            let script = tree.appendingPathComponent("agent")
            try "#!/bin/sh\necho \(version)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let zip = directory.appendingPathComponent("agent-\(version).zip")
            try Self.run("/usr/bin/ditto", ["-c", "-k", tree.path, zip.path])
            let sha = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            return (zip, sha)
        }

        func binaryEntry(id: String = "demo", version: String, archive: (url: URL, sha256: String)) -> String {
            #"""
            {"id":"\#(id)","name":"Demo","version":"\#(version)","distribution":{"binary":{"darwin-aarch64":
             {"archive":"\#(archive.url.absoluteString)","cmd":"./agent","args":["--acp"],
              "env":{"REGISTRY_ONLY":"1","SHARED":"registry"},"sha256":"\#(archive.sha256)"}}}}
            """#
        }

        func npxEntry(id: String = "codex", version: String) -> String {
            #"{"id":"\#(id)","name":"Codex","version":"\#(version)","distribution":{"npx":{"package":"@agentclientprotocol/codex-acp@\#(version)","args":["--stdio"]}}}"#
        }

        /// `node` and an `npm` that lays out what `npm install --prefix` produces, logging each run.
        func installNodeTools() throws {
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            try Self.script("#!/bin/sh\nexit 0\n", at: tools.appendingPathComponent("node"))
            try Self.script("""
            #!/bin/sh
            echo "run $*" >> "\(npmLog.path)"
            prefix=""; spec=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --prefix) prefix="$2"; shift 2 ;;
                install|--*) shift ;;
                *) spec="$1"; shift ;;
              esac
            done
            name="${spec%@*}"
            unscoped="${name##*/}"
            mkdir -p "$prefix/node_modules/$name/dist"
            printf '{"name": "%s", "bin": {"%s": "dist/index.js"}}' "$name" "$unscoped" > "$prefix/node_modules/$name/package.json"
            echo 'console.log("agent")' > "$prefix/node_modules/$name/dist/index.js"
            """, at: tools.appendingPathComponent("npm"))
        }

        var npmRuns: Int {
            ((try? String(contentsOf: npmLog, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        func launcher(
            support: ACPSupport,
            cliPath: URL? = URL(fileURLWithPath: "/usr/local/bin/demo"),
            withNode: Bool = true,
            shellEnvironment: [String: String] = [:]
        ) -> ChatLauncher {
            let tools = tools
            return ChatLauncher(
                agentName: "Demo Agent",
                support: support,
                cliPath: cliPath,
                loginPATH: ChatLauncherTests.loginPATH,
                shellEnvironment: shellEnvironment,
                locate: { name in
                    let url = tools.appendingPathComponent(name)
                    return withNode && FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
                },
                registry: ACPRegistryStore(cacheDirectory: cache, indexURL: source),
                installer: ACPInstaller(root: root),
                platform: .darwinArm64
            )
        }

        static func script(_ text: String, at url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        static func run(_ tool: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
        }
    }

    private static let registrySupport = ACPSupport(
        registryID: "demo",
        launch: .registry(cliExecutableVariable: "DEMO_EXECUTABLE"),
        sharesConversationIDs: true,
        environment: ["SHARED": "adapter", "ADAPTER_ONLY": "1", "PATH": "/ignored"]
    )

    private static let codexSupport = ACPSupport(registryID: "codex", launch: .registry(cliExecutableVariable: nil), sharesConversationIDs: true)

    // MARK: CLI launches

    @Test func cliLaunchRunsTheUsersOwnCLI() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let support = ACPSupport(registryID: "opencode", launch: .cli(arguments: ["acp"]), sharesConversationIDs: true, environment: ["A": "B"])
        let launch = try await box.launcher(support: support, cliPath: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")).resolve()
        #expect(launch == ChatLaunch(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
            arguments: ["acp"],
            environment: ["A": "B", "PATH": Self.loginPATH]
        ))
        #expect(try await box.launcher(support: support).checkForUpdate() == nil)
    }

    @Test func theShellsVariablesGiveWayToTheAdaptersAndPATH() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let support = ACPSupport(registryID: "opencode", launch: .cli(arguments: ["acp"]), sharesConversationIDs: true, environment: ["A": "B"])
        let launcher = box.launcher(
            support: support,
            cliPath: URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
            shellEnvironment: ["ANTHROPIC_API_KEY": "key", "A": "shell", "PATH": "/shell/bin"]
        )
        #expect(try await launcher.resolve().environment == ["ANTHROPIC_API_KEY": "key", "A": "B", "PATH": Self.loginPATH])
    }

    @Test func theAppsOwnSessionVariablesAreNotInherited() {
        let inherited = ChatAgentConnection.inheritedEnvironment([
            "HOME": "/Users/me",
            "ARCHIPEL_SESSION_ID": "parent-tab",
            "ARCHIPEL_SOCKET": "/tmp/parent.sock",
        ])
        #expect(inherited == ["HOME": "/Users/me"])
    }

    @Test func cliLaunchNeedsTheCLI() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let support = ACPSupport(registryID: "opencode", launch: .cli(arguments: ["acp"]), sharesConversationIDs: true)
        await #expect(throws: ChatLaunchError.cliNotInstalled(agentName: "Demo Agent")) {
            try await box.launcher(support: support, cliPath: nil).resolve()
        }
        #expect(ChatLaunchError.cliNotInstalled(agentName: "OpenCode").localizedDescription == "OpenCode is not installed.")
    }

    // MARK: Registry binaries

    @Test func binaryIsInstalledThenStartsOfflineAndUpdatesOnRequest() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let first = try box.archive(version: "1.0.0")
        try box.writeRegistry(box.binaryEntry(version: "1.0.0", archive: first))
        let launcher = box.launcher(support: Self.registrySupport)

        let progress = Locked<[ChatLauncher.Progress]>([])
        let launch = try await launcher.resolve { step in progress.withLock { $0.append(step) } }
        let installDirectory = box.root.appendingPathComponent("demo/1.0.0").resolvingSymlinksInPath()
        #expect(launch.executable.path == installDirectory.appendingPathComponent("agent").path)
        #expect(launch.arguments == ["--acp"])
        #expect(launch.environment == [
            "REGISTRY_ONLY": "1",
            "SHARED": "adapter",
            "ADAPTER_ONLY": "1",
            "DEMO_EXECUTABLE": "/usr/local/bin/demo",
            "PATH": Self.loginPATH,
        ])
        let steps = progress.withLock { $0 }
        #expect(steps.first == .checkingRegistry)
        #expect(steps.contains(.downloading(fraction: 1)))
        #expect(steps.last == .done)

        // The registry moves on, but a start keeps using what is installed and never downloads.
        let second = try box.archive(version: "2.0.0")
        try box.writeRegistry(box.binaryEntry(version: "2.0.0", archive: second))
        progress.withLock { $0 = [] }
        let again = try await launcher.resolve { step in progress.withLock { $0.append(step) } }
        #expect(again.executable == launch.executable)
        #expect(progress.withLock { $0 } == [.done])

        let check = try await launcher.checkForUpdate()
        #expect(check == ChatAgentUpdateCheck(installedVersion: "1.0.0", latestVersion: "2.0.0"))
        #expect(check?.isUpdateAvailable == true)

        #expect(try await launcher.update() == "2.0.0")
        // 1.0.0 was handed out for a launch in this run, so a chat may still be running it.
        #expect(await ACPInstaller(root: box.root).installedVersions(of: "demo") == ["1.0.0", "2.0.0"])
        let updated = try await launcher.resolve()
        #expect(updated.executable.path.contains("/demo/2.0.0/"))
        #expect(try await launcher.checkForUpdate()?.isUpdateAvailable == false)
        #expect(await launcher.installedAdapter() == ChatInstalledAdapter(version: "2.0.0", source: .binary, checksumVerified: true))

        // The next run cleans it up.
        #expect(try await box.launcher(support: Self.registrySupport).update() == "2.0.0")
        #expect(await ACPInstaller(root: box.root).installedVersions(of: "demo") == ["2.0.0"])
    }

    @Test func updatesNeedTheRegistryItself() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let first = try box.archive(version: "1.0.0")
        try box.writeRegistry(box.binaryEntry(version: "1.0.0", archive: first))
        let launcher = box.launcher(support: Self.registrySupport)
        _ = try await launcher.resolve()

        // Offline: the cached copy would say "up to date", which nobody checked.
        try FileManager.default.removeItem(at: box.source)
        await #expect(throws: ChatLaunchError.registryUnreachable) { try await launcher.checkForUpdate() }
        await #expect(throws: ChatLaunchError.registryUnreachable) { try await launcher.update() }
        #expect(ChatLaunchError.registryUnreachable.localizedDescription == "Couldn't reach the registry.")
    }

    @Test func updateNeverGoesBackToAnOlderVersion() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let newer = try box.archive(version: "2.0.0")
        try box.writeRegistry(box.binaryEntry(version: "2.0.0", archive: newer))
        _ = try await box.launcher(support: Self.registrySupport).resolve()

        let older = try box.archive(version: "1.9.0")
        try box.writeRegistry(box.binaryEntry(version: "1.9.0", archive: older))
        #expect(try await box.launcher(support: Self.registrySupport).update() == "2.0.0")
        #expect(await ACPInstaller(root: box.root).installedVersions(of: "demo") == ["2.0.0"])
    }

    @Test func cliVariableIsOnlySetWhenTheCLIIsKnown() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.writeRegistry(box.binaryEntry(version: "1.0.0", archive: try box.archive(version: "1.0.0")))
        let launch = try await box.launcher(support: Self.registrySupport, cliPath: nil).resolve()
        #expect(launch.environment["DEMO_EXECUTABLE"] == nil)
        #expect(launch.environment["PATH"] == Self.loginPATH)
    }

    @Test func badChecksumIsAnInstallFailure() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.archive(version: "1.0.0")
        try box.writeRegistry(box.binaryEntry(version: "1.0.0", archive: (archive.url, String(repeating: "0", count: 64))))
        do {
            _ = try await box.launcher(support: Self.registrySupport).resolve()
            Issue.record("expected a failure")
        } catch let error {
            guard case let .installFailed(agentName, reason) = error else {
                Issue.record("expected installFailed, got \(error)")
                return
            }
            #expect(agentName == "Demo Agent")
            #expect(reason.contains("checksum"))
            #expect(error.localizedDescription.hasPrefix("Couldn't install Demo Agent. "))
        }
    }

    @Test func unknownOrUnsupportedAgentsFail() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.writeRegistry(#"{"id":"py","name":"Py","version":"1.0.0","distribution":{"uvx":{"package":"py-acp"}}}"#)
        await #expect(throws: ChatLaunchError.notInRegistry(agentName: "Demo Agent")) {
            try await box.launcher(support: Self.registrySupport).resolve()
        }
        let uvx = ACPSupport(registryID: "py", launch: .registry(cliExecutableVariable: nil), sharesConversationIDs: false)
        await #expect(throws: ChatLaunchError.unsupportedDistribution(agentName: "Demo Agent")) {
            try await box.launcher(support: uvx).resolve()
        }
    }

    // MARK: npm packages

    @Test func npmPackageNeedsNode() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.writeRegistry(box.npxEntry(version: "2.10.0"))
        try box.installNodeTools()
        await #expect(throws: ChatLaunchError.nodeMissing(agentName: "Demo Agent")) {
            try await box.launcher(support: Self.codexSupport, withNode: false).resolve()
        }
        #expect(box.npmRuns == 0)
        #expect(ChatLaunchError.nodeMissing(agentName: "Codex").localizedDescription == "Node.js is required to run Codex as a chat.")
    }

    @Test func npmPackageIsInstalledOnceAndPinned() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.writeRegistry(box.npxEntry(version: "2.10.0"))
        try box.installNodeTools()
        let launcher = box.launcher(support: Self.codexSupport)

        let progress = Locked<[ChatLauncher.Progress]>([])
        let launch = try await launcher.resolve { step in progress.withLock { $0.append(step) } }
        #expect(launch.executable == box.tools.appendingPathComponent("node"))
        #expect(launch.arguments.count == 2)
        #expect(launch.arguments.first?.hasSuffix("/codex/2.10.0/node_modules/@agentclientprotocol/codex-acp/dist/index.js") == true)
        #expect(launch.arguments.last == "--stdio")
        #expect(launch.environment == ["PATH": Self.loginPATH])
        #expect(progress.withLock { $0 } == [.checkingRegistry, .installingPackages, .done])
        #expect(box.npmRuns == 1)

        // A newer release in the registry does not trigger npm on start.
        try box.writeRegistry(box.npxEntry(version: "2.11.0"))
        progress.withLock { $0 = [] }
        let again = try await launcher.resolve { step in progress.withLock { $0.append(step) } }
        #expect(again == launch)
        #expect(progress.withLock { $0 } == [.done])
        #expect(box.npmRuns == 1)
    }

    // MARK: Versions

    @Test func versionsCompareNumerically() {
        #expect(ChatLauncher.newest(["0.110.0", "0.9.0", "0.10.2"]) == "0.110.0")
        #expect(ChatLauncher.newest([]) == nil)
        #expect(ChatLauncher.compareVersions("0.9.0", "0.110.0") == .orderedAscending)
        #expect(ChatLauncher.compareVersions("2.10.0", "2.10") == .orderedSame)
        #expect(ChatLauncher.compareVersions("1.0.0-beta.1", "1.0.0") == .orderedAscending)
        #expect(ChatLauncher.compareVersions("v1.2.0", "1.1.9") == .orderedDescending)
        #expect(ChatAgentUpdateCheck(installedVersion: "0.9.0", latestVersion: "0.110.0").isUpdateAvailable)
        #expect(!ChatAgentUpdateCheck(installedVersion: nil, latestVersion: "0.110.0").isUpdateAvailable)
    }

    @Test func pinningRewritesOnlyWhatItCanTrust() {
        let npx = ACPDistribution.npx(package: "@scope/agent@2.11.0", args: ["--x"], env: [:])
        #expect(ChatLauncher.pin(npx, from: "2.11.0", to: "2.10.0") == .npx(package: "@scope/agent@2.10.0", args: ["--x"], env: [:]))
        #expect(ChatLauncher.pin(npx, from: "2.11.0", to: "2.11.0") == npx)
        // The package does not follow the registry's version, so the old spec is unknown.
        #expect(ChatLauncher.pin(npx, from: "3.0.0", to: "2.10.0") == nil)
    }
}
