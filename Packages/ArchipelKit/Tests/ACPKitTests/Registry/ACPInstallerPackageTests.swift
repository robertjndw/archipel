import Foundation
import Testing

@testable import ACPKit

private actor Recorder {
    private(set) var values: [Double] = []
    func add(_ value: Double) { values.append(value) }
}

@Suite("ACP installer, npm packages")
struct ACPInstallerPackageTests {
    private static let package = "@agentclientprotocol/codex-acp@2.10.0"
    private static let searchPath = "/opt/fake-node/bin:/usr/bin:/bin"

    private enum FakeMode {
        /// `bin` is an object keyed by the unscoped package name.
        case objectBin
        case stringBin
        /// Two entries, one of them named like the package.
        case severalBinsWithMatch
        case severalBinsNoMatch
        case noBin
        /// `bin` points at a symlink that leaves the install.
        case escapingBin
        case failure
        case slow
        /// Never finishes; writes its pid to `npm.pid` first.
        case hang
    }

    private struct Sandbox {
        let directory: URL
        let npm: URL
        let node: URL
        var root: URL { directory.appendingPathComponent("install") }
        var log: URL { directory.appendingPathComponent("npm.log") }

        var tools: ACPNodeTools { ACPNodeTools(npm: npm, node: node, path: ACPInstallerPackageTests.searchPath) }

        init(mode: FakeMode = .objectBin) throws {
            directory = try RegistryTestSupport.makeDirectory()
            let tools = directory.appendingPathComponent("tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            npm = tools.appendingPathComponent("npm")
            node = tools.appendingPathComponent("node")
            try Sandbox.script(fakeNpm(mode: mode, log: directory.appendingPathComponent("npm.log")), at: npm)
            try Sandbox.script("#!/bin/sh\nexit 0\n", at: node)
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        /// The pid a hanging npm wrote, once it did.
        func npmPID() -> pid_t? {
            let text = (try? String(contentsOf: directory.appendingPathComponent("npm.pid"), encoding: .utf8)) ?? ""
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// How many times the fake npm ran.
        func runCount() -> Int {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").filter { $0.hasPrefix("args: ") }.count
        }

        func logLines() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func distribution(
            _ package: String = ACPInstallerPackageTests.package, args: [String] = [], env: [String: String] = [:]
        ) -> ACPDistribution {
            .npx(package: package, args: args, env: env)
        }

        private static func script(_ text: String, at url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// A stand-in for npm that lays out the same files a real `npm install --prefix` does.
    private static func fakeNpm(mode: FakeMode, log: URL) -> String {
        var manifestBin = #""bin": {"$unscoped": "dist/index.js"}"#
        var extra = ""
        var preamble = ""
        switch mode {
        case .objectBin: break
        case .stringBin: manifestBin = #""bin": "dist/index.js""#
        case .severalBinsWithMatch: manifestBin = #""bin": {"helper": "dist/index.js", "$unscoped": "dist/index.js"}"#
        case .severalBinsNoMatch: manifestBin = #""bin": {"one": "dist/index.js", "two": "dist/index.js"}"#
        case .noBin: manifestBin = #""private": true"#
        case .escapingBin:
            manifestBin = #""bin": "escape.js""#
            extra = #"ln -s /bin/sh "$prefix/node_modules/$name/escape.js""#
        case .failure: preamble = "echo 'npm ERR! 404 Not Found - boom' >&2\nexit 1"
        case .slow: preamble = "sleep 0.4"
        case .hang: preamble = "echo $$ > \"\(log.deletingLastPathComponent().appendingPathComponent("npm.pid").path)\"\nexec sleep 1000"
        }
        // Closes the printf quoting around the shell variable so it expands.
        let manifestJSON = manifestBin.replacingOccurrences(of: "$unscoped", with: "'\"$unscoped\"'")
        return """
        #!/bin/sh
        echo "args: $*" >> "\(log.path)"
        echo "PATH=$PATH" >> "\(log.path)"
        prefix=""; spec=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --prefix) prefix="$2"; shift 2 ;;
            install|--*) shift ;;
            *) spec="$1"; shift ;;
          esac
        done
        mkdir -p "$prefix/node_modules"
        \(preamble)
        name="${spec%@*}"
        unscoped="${name##*/}"
        mkdir -p "$prefix/node_modules/$name/dist" "$prefix/node_modules/.bin"
        printf '{"name": "%s", "version": "1.0.0", "type": "module", \(manifestJSON)}' "$name" > "$prefix/node_modules/$name/package.json"
        echo 'console.log("agent")' > "$prefix/node_modules/$name/dist/index.js"
        ln -s "../$name/dist/index.js" "$prefix/node_modules/.bin/$unscoped"
        echo '{}' > "$prefix/package.json"
        echo '{}' > "$prefix/package-lock.json"
        \(extra)
        """
    }

    @Test func happyPath() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let installed = try await installer.installPackage(
            agentID: "codex", version: "2.10.0",
            distribution: box.distribution(args: ["--flag"], env: ["A": "B"]), tools: box.tools
        )
        let directory = box.root.appendingPathComponent("codex/2.10.0")
        let js = directory.appendingPathComponent("node_modules/@agentclientprotocol/codex-acp/dist/index.js")
            .resolvingSymlinksInPath()
        #expect(installed.launch.command == .file(box.node))
        #expect(installed.launch.arguments == [js.path, "--flag"])
        #expect(installed.launch.environment == ["A": "B"])
        #expect(installed.launch.arguments[0].hasPrefix(directory.resolvingSymlinksInPath().path + "/"))
        #expect(installed.source == .npmPackage)
        #expect(!installed.checksumVerified)
        #expect(installed.version == "2.10.0")
        #expect(FileManager.default.fileExists(atPath: js.path))
        let marker = directory.appendingPathComponent(ACPInstaller.markerName)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.appendingPathComponent("codex").path) == ["2.10.0"])

        let lines = box.logLines()
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("args: install --prefix ") == true)
        #expect(lines.first?.hasSuffix(" --no-audit --no-fund --loglevel=error \(Self.package)") == true)
        #expect(lines.last == "PATH=\(Self.searchPath)")
    }

    @Test func relativeBinSymlinkSurvivesTheMove() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let installed = try await ACPInstaller(root: box.root).installPackage(
            agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools
        )
        let link = installed.installDirectory.appendingPathComponent("node_modules/.bin/codex-acp")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(!target.hasPrefix("/"))
        let resolved = link.resolvingSymlinksInPath()
        #expect(resolved.lastPathComponent == "index.js")
        #expect(resolved.path.hasPrefix(installed.installDirectory.resolvingSymlinksInPath().path + "/"))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test func reportsProgressOnlyAtCompletion() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let recorder = Recorder()
        _ = try await ACPInstaller(root: box.root).installPackage(
            agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools,
            progress: { await recorder.add($0) }
        )
        #expect(await recorder.values == [1])
    }

    @Test func alreadyInstalledStartsNoProcess() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let first = try await installer.installPackage(
            agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools
        )
        // Gone tools prove nothing is launched; the node URL is only echoed into the launch spec.
        try FileManager.default.removeItem(at: box.npm)
        let again = try await installer.installPackage(
            agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools
        )
        #expect(again == first, "\(again) vs \(first)")
        #expect(box.runCount() == 1)
    }

    @Test func npmFailureSurfacesStderrAndInstallsNothing() async throws {
        let box = try Sandbox(mode: .failure)
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installPackage(
                agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools
            )
        }
        #expect(error == .npmFailed(stderr: "npm ERR! 404 Not Found - boom"))
        #expect(error?.errorDescription?.contains("boom") == true)
        #expect(await installer.installedVersions(of: "codex").isEmpty)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: box.root.appendingPathComponent("codex").path)) ?? []
        #expect(remaining.isEmpty)
    }

    @Test func missingToolsAreRejectedBeforeNpmRuns() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let missing = box.directory.appendingPathComponent("nope/node")
        let tools = ACPNodeTools(npm: box.npm, node: missing, path: Self.searchPath)
        let error = await #expect(throws: ACPInstallError.self) {
            try await ACPInstaller(root: box.root)
                .installPackage(agentID: "codex", version: "1", distribution: box.distribution(), tools: tools)
        }
        #expect(error == .toolMissing(missing.path))
        #expect(box.runCount() == 0)
    }

    @Test(arguments: [
        "name with spaces@1.0.0",
        "pkg@1.0.0 --registry=https://evil.example",
        "-y@1.0.0",
        "--registry=https://evil.example",
        "git+https://github.com/x/y.git",
        "github:user/repo",
        "file:../x",
        "../x",
        "/abs/path@1.0.0",
        "http://evil.example/x.tgz",
        "https://evil.example/x.tgz@1.0.0",
        "@scope/name",
        "name",
        "name@latest",
        "name@^1.0.0",
        "name@1.0",
        "@scope@1.0.0",
        "@scope/@1.0.0",
        "@/name@1.0.0",
        "name@1.0.0\n--foo",
        "",
    ])
    func invalidSpecsAreRejectedBeforeNpmRuns(spec: String) async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let error = await #expect(throws: ACPInstallError.self) {
            try await ACPInstaller(root: box.root)
                .installPackage(agentID: "demo", version: "1", distribution: box.distribution(spec), tools: box.tools)
        }
        #expect(error == .invalidPackageSpec(spec))
        #expect(box.runCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: box.root.path))
    }

    @Test(arguments: [
        ("@agentclientprotocol/codex-acp@2.10.0", "@agentclientprotocol/codex-acp"),
        ("left-pad@1.3.0", "left-pad"),
        ("@scope/name@1.2.3", "@scope/name"),
        ("pkg@1.0.0-beta.1", "pkg"),
        ("@a/b.c_d@0.0.1+build.5", "@a/b.c_d"),
    ])
    func packageNamesAreParsed(spec: String, name: String) {
        #expect(ACPInstaller.packageName(ofSpec: spec) == name)
    }

    @Test func nonPackageDistributionIsRejected() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let error = await #expect(throws: ACPInstallError.self) {
            try await ACPInstaller(root: box.root).installPackage(
                agentID: "demo", version: "1", distribution: .uvx(package: "x", args: [], env: [:]), tools: box.tools
            )
        }
        #expect(error == .notPackageDistribution)
    }

    @Test func unsafeIdentifiersAreRejected() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        for (id, version) in [("..", "1"), ("a/b", "1"), ("demo", ".."), ("demo", "")] {
            let error = await #expect(throws: ACPInstallError.self) {
                try await ACPInstaller(root: box.root)
                    .installPackage(agentID: id, version: version, distribution: box.distribution(), tools: box.tools)
            }
            #expect(error != nil)
        }
        #expect(box.runCount() == 0)
    }

    @Test func stringBinIsResolved() async throws {
        let box = try Sandbox(mode: .stringBin)
        defer { box.cleanup() }
        let installed = try await ACPInstaller(root: box.root)
            .installPackage(agentID: "demo", version: "1", distribution: box.distribution("tool@1.0.0"), tools: box.tools)
        #expect(installed.launch.arguments.first?.hasSuffix("/node_modules/tool/dist/index.js") == true)
    }

    @Test func severalBinsPreferTheOneNamedLikeThePackage() async throws {
        let box = try Sandbox(mode: .severalBinsWithMatch)
        defer { box.cleanup() }
        let installed = try await ACPInstaller(root: box.root).installPackage(
            agentID: "demo", version: "1", distribution: box.distribution("@s/tool@1.0.0"), tools: box.tools
        )
        #expect(installed.launch.arguments.count == 1)
    }

    @Test func severalBinsWithoutAMatchFail() async throws {
        let box = try Sandbox(mode: .severalBinsNoMatch)
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installPackage(
                agentID: "demo", version: "1", distribution: box.distribution("tool@1.0.0"), tools: box.tools
            )
        }
        guard case .noRunnableBin(let package, let reason)? = error else {
            Issue.record("expected noRunnableBin, got \(String(describing: error))")
            return
        }
        #expect(package == "tool")
        #expect(reason.contains("one, two"))
        #expect(await installer.installedVersions(of: "demo").isEmpty)
    }

    @Test func packageWithoutBinFails() async throws {
        let box = try Sandbox(mode: .noBin)
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installPackage(
                agentID: "demo", version: "1", distribution: box.distribution("tool@1.0.0"), tools: box.tools
            )
        }
        #expect(error == .noRunnableBin(package: "tool", reason: "it declares no bin"))
        #expect(await installer.installedVersions(of: "demo").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("demo/1").path))
    }

    @Test func binLeavingTheInstallThroughASymlinkIsRejected() async throws {
        let box = try Sandbox(mode: .escapingBin)
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installPackage(
                agentID: "demo", version: "1", distribution: box.distribution("tool@1.0.0"), tools: box.tools
            )
        }
        #expect(error == .executableOutsideInstall("escape.js"))
        #expect(await installer.installedVersions(of: "demo").isEmpty)
    }

    @Test func concurrentInstallsShareOneNpmRun() async throws {
        let box = try Sandbox(mode: .slow)
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let distribution = box.distribution()
        let tools = box.tools
        async let first = installer.installPackage(agentID: "codex", version: "2.10.0", distribution: distribution, tools: tools)
        async let second = installer.installPackage(agentID: "codex", version: "2.10.0", distribution: distribution, tools: tools)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(box.runCount() == 1)
    }

    @Test func installedVersionsAndCleanupCoverBothKinds() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        for version in ["1.0.0", "2.0.0"] {
            _ = try await installer.installPackage(
                agentID: "codex", version: version, distribution: box.distribution("@s/codex@\(version)"), tools: box.tools
            )
        }
        let tree = try RegistryTestSupport.makeScriptTree(in: box.directory, at: "agent", output: "bin")
        let archive = box.directory.appendingPathComponent("agent.zip")
        try RegistryTestSupport.makeZip(of: tree, at: archive)
        _ = try await installer.installLocal(
            agentID: "codex", version: "3.0.0",
            distribution: .binary(archive: archive, cmd: "./agent", args: [], env: [:], sha256: nil)
        )
        #expect(await installer.installedVersions(of: "codex") == ["1.0.0", "2.0.0", "3.0.0"])
        await installer.removeOtherVersions(of: "codex", keeping: "2.0.0")
        #expect(await installer.installedVersions(of: "codex") == ["2.0.0"])
    }

    @Test func aBinaryInstallIsNotMistakenForAPackageInstall() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let tree = try RegistryTestSupport.makeScriptTree(in: box.directory, at: "agent", output: "bin")
        let archive = box.directory.appendingPathComponent("agent.zip")
        try RegistryTestSupport.makeZip(of: tree, at: archive)
        _ = try await installer.installLocal(
            agentID: "codex", version: "2.10.0",
            distribution: .binary(archive: archive, cmd: "./agent", args: [], env: [:], sha256: nil)
        )
        let installed = try await installer.installPackage(
            agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools
        )
        #expect(installed.source == .npmPackage)
        #expect(box.runCount() == 1)
    }

    @Test func staleStagingIsSweptButFreshStagingIsKept() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let agentDirectory = box.root.appendingPathComponent("codex")
        let stale = agentDirectory.appendingPathComponent(".staging-old")
        let fresh = agentDirectory.appendingPathComponent(".staging-fresh")
        for url in [stale, fresh] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: stale.path)
        _ = try await ACPInstaller(root: box.root).installPackage(
            agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools
        )
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RegistryTestSupport.FixtureError(message: "timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func npmRunningPastItsTimeLimitIsStopped() async throws {
        let box = try Sandbox(mode: .hang)
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root, npmTimeout: .milliseconds(1500))
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installPackage(agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools)
        }
        #expect(error == .npmTimedOut(minutes: 1))
        let pid = try #require(box.npmPID())
        // Reaped by the time the install gave up, so the pid is free.
        #expect(kill(pid, 0) != 0)
        #expect(await installer.installedVersions(of: "codex").isEmpty)
    }

    @Test func cancellingTheOnlyWaiterStopsNpm() async throws {
        let box = try Sandbox(mode: .hang)
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let install = Task {
            try await installer.installPackage(agentID: "codex", version: "2.10.0", distribution: box.distribution(), tools: box.tools)
        }
        try await Self.waitUntil { box.npmPID() != nil }
        let pid = try #require(box.npmPID())
        install.cancel()
        await #expect(throws: CancellationError.self) { try await install.value }
        try await Self.waitUntil { kill(pid, 0) != 0 }
    }
}
