@testable import ACPKit
import CryptoKit
import Foundation

enum RegistryTestSupport {
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acpkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct FixtureError: Error { var message: String }

    /// Runs a tool to completion and returns its output, failing loudly so a broken fixture is obvious.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FixtureError(message: "\(tool) \(arguments) failed: \(text)")
        }
        return text
    }

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// A directory holding a shell script at `relativePath` that prints `output`.
    static func makeScriptTree(in parent: URL, at relativePath: String, output: String, executable: Bool = true) throws -> URL {
        let tree = parent.appendingPathComponent("tree-\(UUID().uuidString)")
        let script = tree.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \(output)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: script.path)
        return tree
    }

    static func makeZip(of tree: URL, at destination: URL) throws {
        try run("/usr/bin/ditto", ["-c", "-k", tree.path, destination.path])
    }

    static func makeTarGz(of tree: URL, at destination: URL) throws {
        try run("/usr/bin/tar", ["-czf", destination.path, "-C", tree.path, "."])
    }

    static func index(agents: String, version: String = "1.0.0") -> Data {
        Data(#"{"version":"\#(version)","agents":[\#(agents)],"extensions":[]}"#.utf8)
    }
}

extension ACPInstaller {
    /// `install` for archives served from file URLs, as every test here serves them.
    func installLocal(
        agentID: String,
        version: String,
        distribution: ACPDistribution,
        forLaunch: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> ACPInstalledAgent {
        try await install(
            agentID: agentID, version: version, distribution: distribution,
            allowsFileArchives: true, forLaunch: forLaunch, progress: progress
        )
    }
}
