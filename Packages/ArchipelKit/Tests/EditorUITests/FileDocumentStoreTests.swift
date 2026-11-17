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

    @Test func saveRefusesToOverwriteAnUnseenExternalChange() async throws {
        let url = try file("hidden.txt", Data("v1\n".utf8))
        let buffer = await open(url)
        type("mine ", at: 0, in: buffer)

        // No reload in between: the tab is hidden, so nothing watches the file.
        try Data("theirs\n".utf8).write(to: url, options: .atomic)
        #expect(throws: SaveConflictError(fileName: "hidden.txt", conflict: .changed)) { try self.store.save(url) }
        #expect(buffer.conflict == .changed)
        #expect(store.isDirty(url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")

        // Still refused until the conflict is answered, also through Save All.
        #expect(throws: SaveConflictError.self) { try self.store.saveAll() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")

        buffer.keepChanges()
        try store.save(url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine v1\n")
        #expect(!store.isDirty(url))
        #expect(buffer.conflict == nil)
    }

    @Test func keepingChangesDoesNotCoverALaterExternalChange() async throws {
        let url = try file("twice.txt", Data("v1\n".utf8))
        let buffer = await open(url)
        type("mine ", at: 0, in: buffer)
        try Data("v2\n".utf8).write(to: url, options: .atomic)
        #expect(throws: SaveConflictError.self) { try self.store.save(url) }
        buffer.keepChanges()

        try Data("v3\n".utf8).write(to: url, options: .atomic)
        #expect(throws: SaveConflictError.self) { try self.store.save(url) }
        #expect(buffer.conflict == .changed)
        #expect(try String(contentsOf: url, encoding: .utf8) == "v3\n")

        // Reload takes the newest version, not the one the first conflict saw.
        store.discardChanges(url)
        #expect(buffer.text == "v3\n")
    }

    @Test func saveRefusesToRecreateAFileDeletedOnDisk() async throws {
        let url = try file("deleted.txt", Data("v1\n".utf8))
        let buffer = await open(url)
        type("mine ", at: 0, in: buffer)

        try FileManager.default.removeItem(at: url)
        #expect(throws: SaveConflictError(fileName: "deleted.txt", conflict: .deleted)) { try self.store.save(url) }
        #expect(buffer.conflict == .deleted)
        #expect(store.isDirty(url))
        #expect(!FileManager.default.fileExists(atPath: url.path))

        buffer.keepChanges()
        try store.save(url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine v1\n")
        #expect(!store.isDirty(url))
    }

    @Test func saveIgnoresAnExternalRewriteWithTheSameContents() async throws {
        let url = try file("touched.txt", Data("v1\n".utf8))
        let buffer = await open(url)
        type("mine ", at: 0, in: buffer)

        try Data("v1\n".utf8).write(to: url, options: .atomic)
        try store.save(url)
        #expect(buffer.conflict == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine v1\n")
    }

    @Test func conflictClearsWhenTheDiskReturnsToTheSavedText() async throws {
        let url = try file("back.txt", Data("v1\n".utf8))
        let buffer = await open(url)
        type("mine ", at: 0, in: buffer)
        try Data("v2\n".utf8).write(to: url, options: .atomic)
        await buffer.reload()
        #expect(buffer.conflict == .changed)

        try Data("v1\n".utf8).write(to: url, options: .atomic)
        await buffer.reload()
        #expect(buffer.conflict == nil)

        // The stale "v2" must not come back as the disk version.
        store.discardChanges(url)
        #expect(buffer.text == "v1\n")
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

    @Test func textBehindADocumentOrModelExtensionOpensAsText() async throws {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----\n"
        let samples = [
            "server.key": pem,
            "cube.obj": "v 0 0 0\nv 1 0 0\nf 1 2 3\n",
            "cloud.ply": "ply\nformat ascii 1.0\nelement vertex 0\nend_header\n",
            "part.stl": "solid part\nendsolid part\n",
            "scene.dae": "<?xml version=\"1.0\"?>\n<COLLADA></COLLADA>\n",
            "stage.usda": "#usda 1.0\n",
            "icon.xbm": "#define icon_width 1\n#define icon_height 1\nstatic char icon_bits[] = { 0x00 };\n",
        ]
        for (name, text) in samples {
            let buffer = await open(try file(name, Data(text.utf8)))
            #expect(buffer.state == .text, "\(name)")
            #expect(buffer.text == text, "\(name)")
        }
    }

    @Test func binaryAndRenderedDocumentsStayInQuickLook() async throws {
        // Zip container, as Keynote writes it, and a binary STL with its 80-byte header.
        let keynote = await open(try file("deck.key", Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 64)))
        #expect(keynote.state == .preview)
        let stl = await open(try file("mesh.stl", Data("binary stl".utf8) + Data(count: 100)))
        #expect(stl.state == .preview)
        // These read as text in their first bytes and are still not something to edit as text.
        let pdf = await open(try file("paper.pdf", Data("%PDF-1.7\n1 0 obj\n".utf8)))
        #expect(pdf.state == .preview)
        let rtf = await open(try file("note.rtf", Data(#"{\rtf1\ansi Hello}"#.utf8)))
        #expect(rtf.state == .preview)
        let ppm = await open(try file("pixel.ppm", Data("P3\n1 1\n255\n0 0 0\n".utf8)))
        #expect(ppm.state == .preview)
    }

    @Test func aFileReachedThroughASymlinkSharesItsBuffer() async throws {
        let real = try file("real.txt", Data("one\n".utf8))
        let link = folder.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let linkedFolder = folder.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: folder)

        let buffer = await open(link)
        #expect(store.buffer(for: real) === buffer)
        #expect(store.buffer(for: linkedFolder.appending(path: "real.txt")) === buffer)

        type("x", at: 0, in: buffer)
        #expect(store.isDirty(real))
        #expect(store.isDirty(link))
        // Once, and under the path it was opened by.
        #expect(store.dirtyURLs == [link.standardizedFileURL])

        // The tabs for one path closing must not take the buffer away from the others.
        store.close(link)
        #expect(store.buffer(for: real) === buffer)
        #expect(store.isDirty(real))

        try store.save(real)
        #expect(try String(contentsOf: real, encoding: .utf8) == "xone\n")
        #expect(store.dirtyURLs.isEmpty)
        // Still a link, not replaced by a copy of the file.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)

        store.close(linkedFolder.appending(path: "real.txt"))
        store.close(real)
        #expect(store.buffer(for: real) !== buffer)
    }

    @Test func aBufferOpenedThroughALinkOutlivesTheLink() async throws {
        let real = try file("real.txt", Data("one\n".utf8))
        let other = try file("other.txt", Data("other\n".utf8))
        let link = folder.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let buffer = await open(link)
        #expect(store.buffer(for: real) === buffer)
        type("x", at: 0, in: buffer)
        // Still shown under the path the user opened.
        #expect(store.dirtyURLs == [link.standardizedFileURL])

        // With the link gone the file is still there, so this is no "deleted on disk" conflict,
        // and nothing may be written where the link was.
        try FileManager.default.removeItem(at: link)
        try store.save(real)
        #expect(buffer.conflict == nil)
        #expect(try String(contentsOf: real, encoding: .utf8) == "xone\n")
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(store.dirtyURLs.isEmpty)

        // Pointed somewhere else, the link is another file, which this buffer must not touch.
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        type("y", at: 0, in: buffer)
        try store.save(link)
        await buffer.reload()
        #expect(buffer.conflict == nil)
        #expect(try String(contentsOf: real, encoding: .utf8) == "yxone\n")
        #expect(try String(contentsOf: other, encoding: .utf8) == "other\n")
    }

    @Test func forgettingAFileDropsItsBufferUnderEveryPath() async throws {
        let real = try file("AGENTS.md", Data("one\n".utf8))
        let link = folder.appending(path: "CLAUDE.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let unrelated = await open(try file("kept.txt", Data("kept\n".utf8)))
        type("k", at: 0, in: unrelated)

        let buffer = await open(link)
        #expect(store.buffer(for: real) === buffer)
        type("x", at: 0, in: buffer)

        // Closing one path leaves the buffer to the other, which is what a removed worktree
        // must not do: nothing could save the edits any more.
        store.forget(link)
        #expect(!store.isDirty(real))
        #expect(!store.isDirty(link))
        #expect(store.dirtyURLs == [unrelated.url])
        #expect(store.buffer(for: real) !== buffer)
        try store.saveAll()
    }

    @Test func pathsThroughALinkShareABuffer() async throws {
        let real = try file("real.txt", Data("one\n".utf8))
        let other = try file("other.txt", Data("two\n".utf8))
        let link = folder.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(store.sharesBuffer(link, real))
        #expect(store.sharesBuffer(real, folder.appending(path: "./real.txt")))
        #expect(!store.sharesBuffer(real, other))

        // An open buffer keeps both paths even when the link no longer resolves.
        _ = await open(link)
        _ = store.buffer(for: real)
        try FileManager.default.removeItem(at: link)
        #expect(store.sharesBuffer(link, real))
    }

    @Test func aBufferIsStillFoundAfterItsFileIsDeleted() async throws {
        let url = try file("gone.txt", Data("one\n".utf8))
        let buffer = await open(url)
        type("x", at: 0, in: buffer)
        try FileManager.default.removeItem(at: url)

        #expect(store.isDirty(url))
        #expect(store.buffer(for: url) === buffer)
        store.close(url)
        #expect(store.dirtyURLs.isEmpty)
        #expect(store.buffer(for: url) !== buffer)
    }
}
