@testable import ChatUI
import Foundation
import Testing

@Suite
final class ChatLinkPolicyTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, executable: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    private func destination(_ url: URL, packages: Set<String> = []) -> ChatLinkPolicy.Destination? {
        ChatLinkPolicy.destination(for: url) { packages.contains($0.lastPathComponent) }
    }

    @Test func plainFilesOpen() throws {
        let readme = try file("README.md")
        #expect(destination(readme) == .file(readme.standardizedFileURL))
    }

    @Test func anythingThatRunsIsOnlyRevealed() throws {
        let folder = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = directory.appendingPathComponent("Evil.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let bundle = directory.appendingPathComponent("Thing.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        for url in [
            folder, app, bundle,
            try file("run", executable: true),
            try file("install.command"), try file("script.SH"), try file("tool.py"),
            try file("Installer.pkg"), try file("Disk.dmg"), try file("Do It.scpt"), try file("Profile.terminal"),
        ] {
            #expect(destination(url, packages: ["Thing.bundle"]) == .reveal(url.standardizedFileURL), "\(url.lastPathComponent)")
        }
    }

    @Test func aLinkIsJudgedByWhereItLeads() throws {
        let app = directory.appendingPathComponent("Real.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let disguise = directory.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: disguise, withDestinationURL: app)
        #expect(destination(disguise) == .reveal(disguise.standardizedFileURL))
    }

    @Test func otherLinks() throws {
        #expect(destination(try #require(URL(string: "https://example.com/a"))) == .web(try #require(URL(string: "https://example.com/a"))))
        #expect(destination(try #require(URL(string: "mailto:a@example.com"))) == .mail(try #require(URL(string: "mailto:a@example.com"))))
        #expect(destination(try #require(URL(string: "https:///nohost"))) == nil)
        #expect(destination(try #require(URL(string: "x-apple.systempreferences:com.apple.preference"))) == nil)
        #expect(destination(directory.appendingPathComponent("missing.txt")) == nil)
    }
}
