import Foundation
import GitKit
import Testing
@testable import EditorUI

/// What the model's loader returns next, swapped between refreshes.
private actor DiffSource {
    var next: Result<GitFileDiff?, GitError> = .success(nil)

    func set(_ result: Result<GitFileDiff?, GitError>) {
        next = result
    }

    func load() throws -> GitFileDiff? {
        try next.get()
    }
}

private func edit(_ path: String = "notes.txt", from old: String = "a", to new: String = "b", oldPath: String? = nil) -> GitFileDiff {
    GitFileDiff(
        oldPath: oldPath ?? path, newPath: path, status: oldPath == nil ? .modified : .renamed,
        hunks: [GitDiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: [GitDiffLine(.removed, old), GitDiffLine(.added, new)])]
    )
}

@MainActor
struct DiffViewerModelTests {
    private let source = DiffSource()

    private func model(path: String = "notes.txt") -> DiffViewerModel {
        let source = source
        return DiffViewerModel(root: URL(filePath: "/repo"), path: path, staged: false) { _, _, _ in try await source.load() }
    }

    private func show(_ result: Result<GitFileDiff?, GitError>, in model: DiffViewerModel) async {
        await source.set(result)
        await model.refresh()
    }

    @Test func eachKindOfDiffGetsItsOwnPhase() async {
        let model = model()
        await show(.success(nil), in: model)
        #expect(model.phase == .noDifferences)

        await show(.success(edit()), in: model)
        #expect(model.phase == .ready)
        #expect(model.document?.additions == 1)

        await show(.success(GitFileDiff(oldPath: "notes.txt", newPath: "notes.txt", status: .modified, isBinary: true)), in: model)
        #expect(model.phase == .binary)
        // A placeholder must not leave the previous comparison behind.
        #expect(model.document == nil)

        await show(.success(GitFileDiff(oldPath: "notes.txt", newPath: "notes.txt", status: .modified)), in: model)
        #expect(model.phase == .contentUnchanged)

        await show(.success(GitFileDiff(oldPath: "notes.txt", newPath: "notes.txt", status: .modified, isConflicted: true)), in: model)
        #expect(model.phase == .conflicted)
        #expect(model.document == nil)

        await show(.failure(GitError(message: "boom")), in: model)
        #expect(model.phase == .failed("boom"))
    }

    @Test func aConflictIsReportedAsSuchEvenWhenGitAlsoCallsItBinary() async {
        let model = model()
        await show(.success(GitFileDiff(oldPath: "notes.txt", newPath: "notes.txt", status: .modified, isBinary: true, isConflicted: true)), in: model)
        #expect(model.phase == .conflicted)
    }

    @Test func identicalOutputLeavesTheDocumentAlone() async {
        let model = model()
        await show(.success(edit()), in: model)
        #expect(model.documentVersion == 1)
        // The poll: same output, so scroll position and folds have to survive.
        await model.refresh()
        #expect(model.documentVersion == 1)

        await show(.success(edit(to: "c")), in: model)
        #expect(model.documentVersion == 2)
        #expect(model.document?.new.lines == ["c"])
    }

    @Test func theSameDiffIsShownAgainAfterAFailure() async {
        let model = model()
        await show(.success(edit()), in: model)
        await show(.failure(GitError(message: "index.lock exists")), in: model)
        #expect(model.phase == .failed("index.lock exists"))
        #expect(model.document == nil)

        // Equal to the diff shown before the failure, and still has to replace the error.
        await show(.success(edit()), in: model)
        #expect(model.phase == .ready)
        #expect(model.document != nil)
    }

    @Test func renamedFromFollowsTheDiffIncludingPlaceholders() async {
        let model = model(path: "new.txt")
        await show(.success(edit("new.txt", oldPath: "old.txt")), in: model)
        #expect(model.renamedFrom == "old.txt")

        // A pure rename has no hunks, and its header still has to say where it came from.
        await show(.success(GitFileDiff(oldPath: "older.txt", newPath: "new.txt", status: .renamed)), in: model)
        #expect(model.phase == .contentUnchanged)
        #expect(model.renamedFrom == "older.txt")

        await show(.success(edit("new.txt")), in: model)
        #expect(model.renamedFrom == nil)

        await show(.success(edit("new.txt", oldPath: "old.txt")), in: model)
        await show(.success(nil), in: model)
        #expect(model.renamedFrom == nil)
    }
}

/// Against a real merge conflict, so the parser and the model are checked together.
@MainActor
final class DiffViewerConflictTests {
    let repo: URL

    init() throws {
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        repo = URL(filePath: temp).appending(path: "EditorUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "EditorUI Tests")
        try git("config", "user.email", "tests@example.invalid")
        try git("config", "commit.gpgsign", "false")
        try git("config", "core.hooksPath", ".git/no-hooks")
        try write("shared.txt", "base\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "base")
        try git("checkout", "-q", "-b", "other")
        try write("shared.txt", "theirs\n")
        try git("commit", "-q", "-am", "theirs")
        try git("checkout", "-q", "main")
        try write("shared.txt", "ours\n")
        try git("commit", "-q", "-am", "ours")
        try git("merge", "-q", "other")
    }

    deinit {
        try? FileManager.default.removeItem(at: repo)
    }

    @Test func anUnmergedFileShowsTheConflictPlaceholder() async throws {
        #expect(try String(contentsOf: repo.appending(path: "shared.txt"), encoding: .utf8).contains("<<<<<<<"))
        let model = DiffViewerModel(root: repo, path: "shared.txt", staged: false)
        await model.refresh()
        #expect(model.phase == .conflicted)
        #expect(model.document == nil)
    }

    private func write(_ path: String, _ contents: String) throws {
        try contents.write(to: repo.appending(path: path), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
