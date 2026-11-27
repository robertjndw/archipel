import Foundation
import Synchronization
import Testing
@testable import EditorUI

@Suite
final class MarkdownPathLinkerTests {
    private let directory: URL
    private let home = NSHomeDirectory()

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("path-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made.appending(path: "Sources/App"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: made.appending(path: "Sources/App/main.swift"))
        try Data("x".utf8).write(to: made.appending(path: "README.md"))
        try Data("x".utf8).write(to: made.appending(path: "my notes.md"))
        directory = URL(filePath: NSString(string: made.path).standardizingPath)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var root: String { directory.path(percentEncoded: false) }

    private func links(in source: String, linker: MarkdownPathLinker? = nil) throws -> [(text: String, url: URL)] {
        let linker = linker ?? MarkdownPathLinker(base: directory)
        let blocks = MarkdownDocument.parse(source, paths: linker)
        try #require(blocks.count == 1)
        guard case .paragraph(let text) = blocks[0].kind else {
            Issue.record("not a paragraph")
            return []
        }
        return text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0) } }
    }

    private func file(_ relative: String, fragment: String? = nil) -> URL {
        let url = URL(filePath: root + "/" + relative)
        guard let fragment else { return url }
        return URL(string: url.absoluteString + "#" + fragment)!
    }

    // MARK: Prose

    @Test func linksAnAbsoluteFolderInASentence() throws {
        let found = try links(in: "The screenshots are in \(root)/Sources/, each in light and dark:")
        try #require(found.count == 1)
        #expect(found[0].text == "\(root)/Sources/")
        #expect(found[0].url == URL(filePath: "\(root)/Sources"))
    }

    @Test func linksRelativePathsAndPositions() throws {
        let found = try links(in: "See Sources/App/main.swift:12:3 and ./README.md.")
        #expect(found.map(\.text) == ["Sources/App/main.swift:12:3", "./README.md"])
        #expect(found.map(\.url) == [file("Sources/App/main.swift", fragment: "L12C3"), file("README.md")])
    }

    @Test func leavesTheSentenceAroundTheLinkAlone() throws {
        let source = "Look at (Sources/App/main.swift), then stop."
        let blocks = MarkdownDocument.parse(source, paths: MarkdownPathLinker(base: directory))
        guard case .paragraph(let text) = blocks.first?.kind else { Issue.record("not a paragraph"); return }
        #expect(String(text.characters) == source)
        #expect(try links(in: source).map(\.text) == ["Sources/App/main.swift"])
    }

    @Test func ignoresPathsThatDoNotExistAndThingsThatAreNotPaths() throws {
        #expect(try links(in: "Try \(root)/missing.txt or and/or or 1/2.").isEmpty)
        #expect(try links(in: "Or https://example.com/Sources.").allSatisfy { !$0.url.isFileURL })
        #expect(try links(in: "Plain words, nothing else.").isEmpty)
    }

    @Test func needsABaseForRelativePaths() throws {
        #expect(try links(in: "See Sources/App/main.swift.", linker: MarkdownPathLinker(base: nil)).isEmpty)
        #expect(try links(in: "See \(root)/README.md.", linker: MarkdownPathLinker(base: nil)).count == 1)
    }

    @Test func linksNothingWithoutALinker() throws {
        let blocks = MarkdownDocument.parse("See \(root)/README.md and `README.md`.")
        guard case .paragraph(let text) = blocks.first?.kind else { Issue.record("not a paragraph"); return }
        #expect(text.runs.allSatisfy { $0.link == nil })
    }

    // MARK: Code spans and Markdown links

    @Test func linksWholeCodeSpans() throws {
        let found = try links(in: "Edit `README.md`, `my notes.md` and `Sources/App/main.swift:4`, not `true` or `git add README.md`.")
        #expect(found.map(\.text) == ["README.md", "my notes.md", "Sources/App/main.swift:4"])
        #expect(found.last?.url == file("Sources/App/main.swift", fragment: "L4"))
    }

    @Test func resolvesRelativeLinkDestinations() throws {
        let found = try links(in: "[main](Sources/App/main.swift#L7), [readme](README.md:3), [notes](my%20notes.md#intro)")
        #expect(found.map(\.url) == [
            file("Sources/App/main.swift", fragment: "L7"),
            file("README.md", fragment: "L3"),
            file("my notes.md"),
        ])
    }

    @Test func keepsOtherLinksAsWritten() throws {
        let found = try links(in: "[web](https://example.com/a) [missing](nope/x.md) [mail](mailto:a@example.com)")
        #expect(found.map(\.url) == [URL(string: "https://example.com/a"), URL(string: "nope/x.md"), URL(string: "mailto:a@example.com")])
    }

    @Test func doesNotLinkTextInsideALink() throws {
        let found = try links(in: "[see \(root)/README.md](https://example.com)")
        #expect(found.map(\.url) == [URL(string: "https://example.com")])
    }

    // MARK: Safety

    @Test func neverLooksUpNetworkOrDeviceLocations() throws {
        let looked = Mutex<[String]>([])
        let linker = MarkdownPathLinker(base: directory) { path in
            looked.withLock { $0.append(path) }
            return true
        }
        let source = "/net/evil/share/a.txt /Volumes/Share/x /Network/Servers/a /home/u/a /dev/disk0 /System/Volumes/Data/x ~root/x"
        #expect(try links(in: source, linker: linker).isEmpty)
        #expect(try links(in: "/tmp/../net/evil/a.txt", linker: linker).isEmpty)
        #expect(looked.withLock { $0 }.isEmpty)
    }

    @Test func looksUpNetworkLocationsInsideTheBase() throws {
        let linker = MarkdownPathLinker(base: URL(filePath: "/Volumes/Work/project")) { _ in true }
        #expect(try links(in: "See src/a.swift and /Volumes/Other/b.", linker: linker).map(\.url) == [URL(filePath: "/Volumes/Work/project/src/a.swift")])
    }

    @Test func symlinksCannotLeadToRefusedPlaces() throws {
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: root + "/share", withDestinationPath: "/net/evil.example/share")
        try manager.createSymbolicLink(atPath: root + "/hop", withDestinationPath: "share")
        try manager.createSymbolicLink(atPath: root + "/null", withDestinationPath: "/dev/null")
        try manager.createSymbolicLink(atPath: root + "/loop", withDestinationPath: "loop")
        try manager.createSymbolicLink(atPath: root + "/readme-link", withDestinationPath: "README.md")
        let found = try links(in: "share/a.txt hop/a.txt null loop/x ./readme-link")
        #expect(found.map(\.text) == ["./readme-link"])
    }

    @Test func safeLookupKinds() {
        #expect(SafeFileLookup.lookUp("/dev/null", refusing: []) == nil)
        #expect(SafeFileLookup.lookUp("/tmp", refusing: [])?.kind == .folder)
        #expect(SafeFileLookup.lookUp("/tmp", refusing: [])?.path == "/private/tmp")
        #expect(SafeFileLookup.lookUp(root + "/README.md", refusing: [])?.kind == .file)
        #expect(SafeFileLookup.lookUp(root + "/README.md/x", refusing: []) == nil)
        #expect(SafeFileLookup.lookUp(root + "/README.md\u{0}.txt", refusing: []) == nil)
        #expect(SafeFileLookup.lookUp("/net/evil.example/a", refusing: SafeFileLookup.automountPrefixes) == nil)
    }

    @Test func rejectsControlCharacters() throws {
        #expect(try links(in: "[x](README.md%00.txt)").map(\.url) == [URL(string: "README.md%00.txt")])
    }

    @Test func splitsPositionsByHand() {
        #expect(MarkdownPathLinker.splitPosition("a.swift:12")?.1 == MarkdownFilePosition(line: 12))
        #expect(MarkdownPathLinker.splitPosition("a.swift:12:3")?.1 == MarkdownFilePosition(line: 12, column: 3))
        #expect(MarkdownPathLinker.splitPosition("a.swift:12:3")?.0 == "a.swift")
        #expect(MarkdownPathLinker.splitPosition("a.swift:+1") == nil)
        #expect(MarkdownPathLinker.splitPosition(":12") == nil)
        #expect(MarkdownPathLinker.splitPosition("a.swift:0") == nil)
        let clock = ContinuousClock()
        let long = String(repeating: "a:", count: 500) + "x"
        let elapsed = clock.measure { _ = MarkdownPathLinker.splitPosition(long) }
        #expect(elapsed < .milliseconds(50))
    }

    @Test func expandsOnlyTheUsersOwnHome() throws {
        let home = home
        let linker = MarkdownPathLinker(base: directory) { $0.hasPrefix(home + "/") }
        #expect(try links(in: "See ~/notes.txt here.", linker: linker).map(\.url) == [URL(filePath: home + "/notes.txt")])
    }

    @Test func remembersWhatItLookedUp() throws {
        let count = Mutex(0)
        let linker = MarkdownPathLinker(base: directory) { _ in
            count.withLock { $0 += 1 }
            return true
        }
        _ = try links(in: "See /a/b.txt.", linker: linker)
        _ = try links(in: "See /a/b.txt.", linker: linker)
        #expect(count.withLock { $0 } == 1)
    }

    @Test func capsLookupsPerText() throws {
        let count = Mutex(0)
        let linker = MarkdownPathLinker(base: directory) { _ in
            count.withLock { $0 += 1 }
            return false
        }
        let source = (0..<1000).map { "/a/\($0).txt" }.joined(separator: " ")
        _ = try links(in: source, linker: linker)
        // A word that is not found as written is tried once more without a `:line`; these have none.
        #expect(count.withLock { $0 } <= MarkdownPathLinker.lookupsPerText)
    }

    @Test func streamingGivesTheSameLinksAsAFullParse() {
        let source = "First \(root)/README.md\n\nThen Sources/App/main.swift:2 and `README.md`.\n"
        let linker = MarkdownPathLinker(base: directory)
        var parser = MarkdownStreamParser(paths: linker)
        var end = source.startIndex
        while end < source.endIndex {
            end = source.index(after: end)
            parser.update(String(source[..<end]))
        }
        #expect(parser.blocks == MarkdownDocument.parse(source, paths: linker))
    }

    // MARK: Positions

    @Test func readsLineFragments() {
        #expect(MarkdownFilePosition(fragment: "L12") == MarkdownFilePosition(line: 12))
        #expect(MarkdownFilePosition(fragment: "L12C3") == MarkdownFilePosition(line: 12, column: 3))
        #expect(MarkdownFilePosition(fragment: "L12-L20") == MarkdownFilePosition(line: 12))
        #expect(MarkdownFilePosition(fragment: "L0") == nil)
        #expect(MarkdownFilePosition(fragment: "setup") == nil)
    }
}
