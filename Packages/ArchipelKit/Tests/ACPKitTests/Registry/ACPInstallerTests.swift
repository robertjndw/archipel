import Foundation
import Testing

@testable import ACPKit

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Recorder {
    private(set) var values: [Double] = []
    func add(_ value: Double) { values.append(value) }
}

@Suite("ACP installer")
struct ACPInstallerTests {
    private struct Sandbox {
        let directory: URL
        var root: URL { directory.appendingPathComponent("install") }

        init() throws { directory = try RegistryTestSupport.makeDirectory() }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        func zip(script: String = "agent", output: String = "hello") throws -> URL {
            let tree = try RegistryTestSupport.makeScriptTree(in: directory, at: script, output: output)
            let archive = directory.appendingPathComponent("agent-\(UUID().uuidString).zip")
            try RegistryTestSupport.makeZip(of: tree, at: archive)
            return archive
        }

        func distribution(
            _ archive: URL, cmd: String = "./agent", args: [String] = [], env: [String: String] = [:],
            sha256: String? = nil
        ) -> ACPDistribution {
            .binary(archive: archive, cmd: cmd, args: args, env: env, sha256: sha256)
        }
    }

    private func launched(_ agent: ACPInstalledAgent) throws -> String {
        guard case .file(let url) = agent.launch.command else {
            throw RegistryTestSupport.FixtureError(message: "not a file command")
        }
        return try RegistryTestSupport.run(url.path, []).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func zipInstallEndToEnd() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip(output: "from-zip")
        let sha = try RegistryTestSupport.sha256(of: archive)
        let installer = ACPInstaller(root: box.root)
        let installed = try await installer.installLocal(
            agentID: "demo", version: "1.0.0",
            distribution: box.distribution(archive, args: ["acp"], env: ["A": "B"], sha256: sha)
        )
        #expect(installed.checksumVerified)
        #expect(installed.launch.arguments == ["acp"])
        #expect(installed.launch.environment == ["A": "B"])
        #expect(try launched(installed) == "from-zip")
        let marker = installed.installDirectory.appendingPathComponent(ACPInstaller.markerName)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(await installer.installedVersions(of: "demo") == ["1.0.0"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.root.appendingPathComponent("demo").path)
        #expect(leftovers == ["1.0.0"])
    }

    @Test func uppercaseChecksumIsAccepted() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let sha = try RegistryTestSupport.sha256(of: archive).uppercased()
        let installed = try await ACPInstaller(root: box.root)
            .installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive, sha256: sha))
        #expect(installed.checksumVerified)
    }

    @Test func missingChecksumInstallsButIsFlagged() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let installer = ACPInstaller(root: box.root)
        let archive = try box.zip()
        let first = try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        #expect(!first.checksumVerified)
        let again = try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        #expect(!again.checksumVerified)
    }

    @Test func checksumMismatchLeavesNothingBehind() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let installer = ACPInstaller(root: box.root)
        let wrong = String(repeating: "0", count: 64)
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive, sha256: wrong))
        }
        guard case .checksumMismatch(let expected, _)? = error else {
            Issue.record("expected checksum mismatch, got \(String(describing: error))")
            return
        }
        #expect(expected == wrong)
        #expect(await installer.installedVersions(of: "demo").isEmpty)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: box.root.appendingPathComponent("demo").path)) ?? []
        #expect(remaining.isEmpty)
        #expect(error?.errorDescription?.contains("checksum") == true)
    }

    @Test func tarGzInstall() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let tree = try RegistryTestSupport.makeScriptTree(in: box.directory, at: "dist-package/cursor-agent", output: "from-tar")
        let archive = box.directory.appendingPathComponent("agent.tar.gz")
        try RegistryTestSupport.makeTarGz(of: tree, at: archive)
        let installed = try await ACPInstaller(root: box.root).installLocal(
            agentID: "cursor", version: "2",
            distribution: box.distribution(archive, cmd: "./dist-package/cursor-agent")
        )
        #expect(try launched(installed) == "from-tar")
    }

    @Test func rawBinaryInstallGetsExecutableBit() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let raw = box.directory.appendingPathComponent("download-12345")
        try "#!/bin/sh\necho raw\n".write(to: raw, atomically: true, encoding: .utf8)
        let installed = try await ACPInstaller(root: box.root).installLocal(
            agentID: "muse", version: "9", distribution: box.distribution(raw, cmd: "./muse")
        )
        #expect(try launched(installed) == "raw")
    }

    @Test func installingAgainNeedsNoSourceOrNetwork() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip(output: "cached")
        let counter = Counter()
        let installer = ACPInstaller(root: box.root, onDownload: { _ in await counter.increment() })
        _ = try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        try FileManager.default.removeItem(at: archive)
        let again = try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        #expect(try launched(again) == "cached")
        #expect(await counter.value == 1)
    }

    @Test func incompleteDirectoryIsNotTreatedAsInstalled() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip(output: "fresh")
        let half = box.root.appendingPathComponent("demo/1")
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        try "#!/bin/sh\necho stale\n".write(to: half.appendingPathComponent("agent"), atomically: true, encoding: .utf8)
        let installer = ACPInstaller(root: box.root)
        #expect(await installer.installedVersions(of: "demo").isEmpty)
        let installed = try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        #expect(try launched(installed) == "fresh")
    }

    @Test func traversingCommandsAreRejected() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let installer = ACPInstaller(root: box.root)
        for cmd in ["../../bin/sh", "/bin/sh", "./a/../../b", "", "~/x"] {
            let error = await #expect(throws: ACPInstallError.self) {
                try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive, cmd: cmd))
            }
            #expect(error == .invalidCommand(cmd), "cmd \(cmd)")
        }
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("demo").path))
    }

    @Test func unsafeIdentifiersAreRejected() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let installer = ACPInstaller(root: box.root)
        for (id, version) in [("..", "1"), ("a/b", "1"), ("demo", ".."), ("demo", "")] {
            let error = await #expect(throws: ACPInstallError.self) {
                try await installer.installLocal(agentID: id, version: version, distribution: box.distribution(archive))
            }
            #expect(error != nil)
        }
    }

    @Test func symlinkedExecutableOutsideTheInstallIsRejected() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let tree = box.directory.appendingPathComponent("linktree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("agent").path, withDestinationPath: "/bin/sh")
        let archive = box.directory.appendingPathComponent("link.tar.gz")
        try RegistryTestSupport.makeTarGz(of: tree, at: archive)
        let installer = ACPInstaller(root: box.root)
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        }
        #expect(error == .executableOutsideInstall("./agent"))
        #expect(await installer.installedVersions(of: "demo").isEmpty)
    }

    @Test func archiveEntriesClimbingOutAreNeverInstalled() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let work = box.directory.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho ok\n".write(to: work.appendingPathComponent("inner/agent"), atomically: true, encoding: .utf8)
        try "evil".write(to: work.appendingPathComponent("escape.txt"), atomically: true, encoding: .utf8)
        let archive = box.directory.appendingPathComponent("evil.tar.gz")
        // -P keeps the leading "../" that tar would normally strip when creating the archive.
        try RegistryTestSupport.run("/usr/bin/tar", ["-czP", "-f", archive.path, "-C", work.appendingPathComponent("inner").path, "agent", "../escape.txt"])
        let installer = ACPInstaller(root: box.root)
        do {
            _ = try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        } catch {
            // Rejecting the archive outright is as good as extracting it safely.
        }
        let escaped = box.root.appendingPathComponent("demo/escape.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: box.root.appendingPathComponent("demo").path)) ?? []
        #expect(!staging.contains { $0.hasPrefix(".staging-") })
    }

    @Test func missingExecutableInArchive() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip(script: "something-else")
        let installer = ACPInstaller(root: box.root)
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        }
        #expect(error == .executableMissing("./agent"))
        #expect(await installer.installedVersions(of: "demo").isEmpty)
    }

    @Test func corruptArchiveReportsToolStderr() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = box.directory.appendingPathComponent("broken.zip")
        try Data("this is not a zip".utf8).write(to: archive)
        let installer = ACPInstaller(root: box.root)
        let error = await #expect(throws: ACPInstallError.self) {
            try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        }
        guard case .unpackFailed(let tool, _)? = error else {
            Issue.record("expected unpackFailed, got \(String(describing: error))")
            return
        }
        #expect(tool == "/usr/bin/ditto")
        #expect(await installer.installedVersions(of: "demo").isEmpty)
    }

    @Test func unsupportedArchiveFormat() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = box.directory.appendingPathComponent("agent.dmg")
        try Data("x".utf8).write(to: archive)
        let error = await #expect(throws: ACPInstallError.self) {
            try await ACPInstaller(root: box.root)
                .installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive))
        }
        #expect(error == .unsupportedArchive("agent.dmg"))
    }

    @Test func missingSourceIsADownloadError() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let error = await #expect(throws: ACPInstallError.self) {
            try await ACPInstaller(root: box.root).installLocal(
                agentID: "demo", version: "1",
                distribution: box.distribution(box.directory.appendingPathComponent("nope.zip"))
            )
        }
        #expect(error != nil)
    }

    @Test func nonBinaryDistributionIsRejected() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let error = await #expect(throws: ACPInstallError.self) {
            try await ACPInstaller(root: box.root)
                .installLocal(agentID: "demo", version: "1", distribution: .npx(package: "x", args: [], env: [:]))
        }
        #expect(error == .notBinaryDistribution)
    }

    @Test func concurrentInstallsShareOneDownload() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip(output: "shared")
        let counter = Counter()
        let installer = ACPInstaller(root: box.root, onDownload: { _ in
            await counter.increment()
            // Long enough that the second call arrives while the first is still downloading.
            try? await Task.sleep(for: .milliseconds(300))
        })
        let distribution = box.distribution(archive)
        async let first = installer.installLocal(agentID: "demo", version: "1", distribution: distribution)
        async let second = installer.installLocal(agentID: "demo", version: "1", distribution: distribution)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(await counter.value == 1)
        #expect(try launched(a) == "shared")
    }

    @Test func progressReachesOne() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let recorder = Recorder()
        _ = try await ACPInstaller(root: box.root).installLocal(
            agentID: "demo", version: "1", distribution: box.distribution(archive),
            progress: { await recorder.add($0) }
        )
        let values = await recorder.values
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values == values.sorted())
    }

    @Test func progressIsReportedForLargeFiles() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        // 24 MB of zeros, stored in a raw install so the size is not hidden by compression.
        let raw = box.directory.appendingPathComponent("big.bin")
        try Data(count: 24 << 20).write(to: raw)
        let recorder = Recorder()
        _ = try await ACPInstaller(root: box.root).installLocal(
            agentID: "big", version: "1", distribution: box.distribution(raw, cmd: "./big"),
            progress: { await recorder.add($0) }
        )
        let values = await recorder.values
        #expect(values.last == 1)
        #expect(values == values.sorted())
    }

    @Test func removeOtherVersionsKeepsOnlyTheNamedOne() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let installer = ACPInstaller(root: box.root)
        for version in ["1", "2", "3"] {
            _ = try await installer.installLocal(agentID: "demo", version: version, distribution: box.distribution(archive))
        }
        _ = try await installer.installLocal(agentID: "other", version: "1", distribution: box.distribution(archive))
        #expect(await installer.installedVersions(of: "demo") == ["1", "2", "3"])
        await installer.removeOtherVersions(of: "demo", keeping: "2")
        #expect(await installer.installedVersions(of: "demo") == ["2"])
        #expect(await installer.installedVersions(of: "other") == ["1"])
    }

    @Test func launchedVersionsSurviveRemovingOtherVersions() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let installer = ACPInstaller(root: box.root)
        _ = try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive), forLaunch: true)
        for version in ["2", "3"] {
            _ = try await installer.installLocal(agentID: "demo", version: version, distribution: box.distribution(archive))
        }
        await installer.removeOtherVersions(of: "demo", keeping: "3")
        #expect(await installer.installedVersions(of: "demo") == ["1", "3"])
    }

    @Test func aRealRegistryMayNotPointAtLocalFiles() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let error = await #expect(throws: ACPInstallError.self) {
            try await ACPInstaller(root: box.root).install(agentID: "demo", version: "1", distribution: box.distribution(archive))
        }
        #expect(error == .localArchiveRejected)
    }

    @Test func installRecordSaysWhetherTheDownloadWasVerified() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let sha = try RegistryTestSupport.sha256(of: archive)
        let installer = ACPInstaller(root: box.root)
        _ = try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive, sha256: sha))
        _ = try await installer.installLocal(agentID: "demo", version: "2", distribution: box.distribution(archive))
        #expect(await installer.installRecord(of: "demo", version: "1") == .init(source: .binary, checksumVerified: true))
        #expect(await installer.installRecord(of: "demo", version: "2") == .init(source: .binary, checksumVerified: false))
        #expect(await installer.installRecord(of: "demo", version: "3") == nil)
    }

    @Test func aCancelledWaiterLeavesASharedInstallToTheOthers() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip(output: "shared")
        let counter = Counter()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let installer = ACPInstaller(root: box.root, onDownload: { _ in
            await counter.increment()
            for await _ in gate { break }
        })
        let distribution = box.distribution(archive)
        let first = Task { try await installer.installLocal(agentID: "demo", version: "1", distribution: distribution) }
        let second = Task { try await installer.installLocal(agentID: "demo", version: "1", distribution: distribution) }
        try await Self.waitUntil { await installer.waiterCount(agentID: "demo", version: "1") == 2 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        open.yield()
        let installed = try await second.value
        #expect(try launched(installed) == "shared")
        #expect(await counter.value == 1)
    }

    @Test func cancellingTheLastWaiterAbandonsTheInstall() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let archive = try box.zip()
        let counter = Counter()
        let installer = ACPInstaller(root: box.root, onDownload: { _ in
            await counter.increment()
            // Cancellation ends the sleep early, which is what the abandoned install must see.
            try? await Task.sleep(for: .seconds(30))
        })
        let first = Task { try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive)) }
        try await Self.waitUntil { await counter.value == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        // A new request starts its own install rather than joining the cancelled one.
        let again = Task { try await installer.installLocal(agentID: "demo", version: "1", distribution: box.distribution(archive)) }
        try await Self.waitUntil { await counter.value == 2 }
        again.cancel()
        await #expect(throws: CancellationError.self) { try await again.value }
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw RegistryTestSupport.FixtureError(message: "timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
