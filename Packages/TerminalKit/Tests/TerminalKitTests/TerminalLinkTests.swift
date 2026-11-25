import Foundation
import Testing
@testable import TerminalKit

struct TerminalLinkTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "terminallink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    private func touch(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data())
        return url
    }

    @Test func relativePathResolvesAgainstBase() throws {
        let dir = try makeDirectory()
        let file = try touch("Sub/foo.swift", in: dir)
        let link = TerminalLink("Sub/foo.swift", relativeTo: dir)
        #expect(link == .file(file, position: nil))
    }

    @Test func tildeExpandsToHome() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
        let link = TerminalLink("~", relativeTo: URL(filePath: "/nonexistent"))
        #expect(link?.url.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func lineSuffixIsSplitOff() throws {
        let dir = try makeDirectory()
        let file = try touch("foo.swift", in: dir)
        #expect(TerminalLink("foo.swift:12", relativeTo: dir) == .file(file, position: .init(line: 12)))
    }

    @Test func lineAndColumnSuffix() throws {
        let dir = try makeDirectory()
        let file = try touch("foo.swift", in: dir)
        #expect(TerminalLink("foo.swift:12:4", relativeTo: dir) == .file(file, position: .init(line: 12, column: 4)))
    }

    @Test func fileNamedWithColonSuffixWins() throws {
        let dir = try makeDirectory()
        _ = try touch("foo.swift", in: dir)
        let odd = try touch("foo.swift:1", in: dir)
        #expect(TerminalLink("foo.swift:1", relativeTo: dir) == .file(odd, position: nil))
    }

    @Test func missingFileIsRefused() throws {
        let dir = try makeDirectory()
        #expect(TerminalLink("nope.swift", relativeTo: dir) == nil)
        #expect(TerminalLink("nope.swift:3", relativeTo: dir) == nil)
    }

    @Test func lineZeroIsRefused() throws {
        let dir = try makeDirectory()
        _ = try touch("foo.swift", in: dir)
        #expect(TerminalLink("foo.swift:0", relativeTo: dir) == nil)
    }

    @Test func fileURLHasNoPosition() throws {
        let dir = try makeDirectory()
        let file = try touch("foo.swift", in: dir)
        #expect(TerminalLink(file.absoluteString, relativeTo: nil) == .file(file, position: nil))
    }

    @Test func webLinkIsAccepted() {
        let url = URL(string: "https://example.com/a")!
        #expect(TerminalLink("https://example.com/a", relativeTo: nil) == .web(url))
        #expect(TerminalLink("https:///a", relativeTo: nil) == nil)
    }

    @Test func customSchemeIsRefused() {
        #expect(TerminalLink("vscode://file/etc/hosts", relativeTo: nil) == nil)
    }
}
