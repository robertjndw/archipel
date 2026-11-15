import AppKit
import Testing
@testable import EditorUI

@MainActor
final class FileDocumentStoreTests {
    let folder: URL
    let store = FileDocumentStore()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "EditorUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ data: Data, permissions: Int = 0o644) throws -> URL {
        let url = folder.appending(path: name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    private func open(_ url: URL) async -> TextBuffer {
        let buffer = store.buffer(for: url)
        await buffer.reload()
        return buffer
    }

    /// Stands in for typing: an edit made through the text storage, which is what NSTextView does.
    private func type(_ text: String, at location: Int, in buffer: TextBuffer) {
        buffer.textStorage.replaceCharacters(in: NSRange(location: location, length: 0), with: text)
    }

    @Test func tracksDirtinessAgainstTheSavedText() async throws {
        let url = try file("a.swift", Data("let a = 1\n".utf8))
        let buffer = await open(url)
        #expect(buffer.state == .text)
        #expect(!store.isDirty(url))

        type("x", at: 0, in: buffer)
        #expect(store.isDirty(url))
        #expect(store.dirtyURLs == [url.standardizedFileURL])

        buffer.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        #expect(!store.isDirty(url))
        #expect(store.dirtyURLs.isEmpty)
    }

    @Test func saveRoundTripPreservesFormatAndPermissions() async throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\r\nthree".utf8)
        let url = try file("crlf.txt", original, permissions: 0o600)
        let buffer = await open(url)
        #expect(buffer.text == "one\ntwo\nthree")

        type("!", at: 3, in: buffer)
        try store.save(url)
        #expect(!store.isDirty(url))
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data("one!\r\ntwo\r\nthree".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        // Our own save is not an external change.
        await buffer.reload()
        #expect(buffer.conflict == nil)
        #expect(buffer.text == "one!\ntwo\nthree")
    }

    @Test func saveKeepsUTF16AndLatin1() async throws {
        let utf16 = Data([0xFF, 0xFE]) + "h\u{e9}\n".data(using: .utf16LittleEndian)!
        let utf16URL = try file("wide.txt", utf16)
        let utf16Buffer = await open(utf16URL)
        type("y", at: 0, in: utf16Buffer)
        try store.save(utf16URL)
        #expect(try Data(contentsOf: utf16URL) == Data([0xFF, 0xFE]) + "yh\u{e9}\n".data(using: .utf16LittleEndian)!)

        let latin1URL = try file("legacy.txt", Data([0x63, 0x61, 0x66, 0xE9]))
        let latin1Buffer = await open(latin1URL)
        type("!", at: 4, in: latin1Buffer)
        try store.save(latin1URL)
        #expect(try Data(contentsOf: latin1URL) == Data([0x63, 0x61, 0x66, 0xE9, 0x21]))

        type("\u{1F600}", at: 0, in: latin1Buffer)
        #expect(throws: (any Error).self) { try self.store.save(latin1URL) }
        #expect(latin1Buffer.saveError != nil)
        #expect(store.isDirty(latin1URL))
    }

    @Test func externalChangeReloadsCleanBuffersAndFlagsDirtyOnes() async throws {
        let url = try file("live.txt", Data("v1\n".utf8))
        let buffer = await open(url)

        try Data("v2\n".utf8).write(to: url, options: .atomic)
        await buffer.reload()
        #expect(buffer.text == "v2\n")
        #expect(buffer.conflict == nil)

        type("mine ", at: 0, in: buffer)
        try Data("v3\n".utf8).write(to: url, options: .atomic)
        await buffer.reload()
        #expect(buffer.conflict == .changed)
        #expect(buffer.text == "mine v2\n")

        buffer.keepChanges()
        #expect(buffer.conflict == nil)
        try store.save(url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine v2\n")
    }

    @Test func discardTakesTheDiskVersion() async throws {
        let url = try file("discard.txt", Data("disk\n".utf8))
        let buffer = await open(url)
        type("edit ", at: 0, in: buffer)
        try Data("newer\n".utf8).write(to: url, options: .atomic)
        await buffer.reload()
        #expect(buffer.conflict == .changed)

        store.discardChanges(url)
        #expect(buffer.text == "newer\n")
        #expect(!store.isDirty(url))
        #expect(buffer.conflict == nil)
        #expect(!buffer.undoManager.canUndo)

        type("again ", at: 0, in: buffer)
        store.discardChanges(url)
        #expect(buffer.text == "newer\n")
    }

    @Test func deletionWhileCleanAndRecovery() async throws {
        let url = try file("gone.txt", Data("here\n".utf8))
        let buffer = await open(url)
        try FileManager.default.removeItem(at: url)
        await buffer.reload()
        #expect(buffer.state == .missing)

        try Data("back\n".utf8).write(to: url)
        await buffer.reload()
        #expect(buffer.state == .text)
        #expect(buffer.text == "back\n")
    }

    @Test func oneBufferPerFileAndCloseForgetsIt() async throws {
        let url = try file("shared.txt", Data("x\n".utf8))
        let first = store.buffer(for: url)
        let second = store.buffer(for: folder.appending(path: "./shared.txt"))
        #expect(first === second)

        await first.reload()
        type("y", at: 0, in: first)
        #expect(store.isDirty(url))
        store.close(url)
        #expect(!store.isDirty(url))
        #expect(store.buffer(for: url) !== first)
    }

    @Test func nonTextFilesAreNotEditable() async throws {
        let binary = await open(try file("blob.bin", Data([0, 1, 2])))
        #expect(binary.state == .binary)
        let image = await open(try file("pic.png", Data([0x89, 0x50, 0x4E, 0x47])))
        #expect(image.state == .preview)
        try store.save(image.url)
    }

    @Test func typeScriptIsNotMistakenForVideo() async throws {
        let source = await open(try file("index.ts", Data("export const a = 1\n".utf8)))
        #expect(source.state == .text)
        let module = await open(try file("index.mts", Data("export {}\n".utf8)))
        #expect(module.state == .text)
        // An actual transport stream: 188-byte packets starting with the 0x47 sync byte.
        let stream = await open(try file("clip.ts", Data([0x47, 0x40, 0x00, 0x10]) + Data(count: 184)))
        #expect(stream.state == .preview)
    }
}
