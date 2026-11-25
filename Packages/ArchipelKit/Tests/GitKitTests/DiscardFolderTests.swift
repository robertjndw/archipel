import Foundation
import Testing
@testable import GitKit

/// The folder that stands in for the system Trash in the UI test build, see `GitClient.discardInto`.
struct DiscardFolderTests {
    private let base = FileManager.default.temporaryDirectory.appending(path: "DiscardFolderTests-\(UUID().uuidString)")

    private func makeFile(_ name: String, _ text: String) throws -> URL {
        let folder = base.appending(path: "repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func aDiscardedFileIsMovedIntoTheFolderNotDeleted() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile("draft.txt", "not ready yet\n")
        let trash = base.appending(path: "Trash")

        try GitProcess.move(file, into: trash)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: trash.appending(path: "draft.txt"), encoding: .utf8) == "not ready yet\n")
    }

    @Test func aSecondFileOfTheSameNameIsKeptBesideTheFirst() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = base.appending(path: "Trash")

        try GitProcess.move(try makeFile("draft.txt", "first\n"), into: trash)
        try GitProcess.move(try makeFile("draft.txt", "second\n"), into: trash)

        let kept = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(kept.count == 2)
        let texts = try kept.map { try String(contentsOf: trash.appending(path: $0), encoding: .utf8) }
        #expect(Set(texts) == ["first\n", "second\n"])
    }
}
