import Foundation
import Testing
@testable import GitKit

/// Root commits are what Locate Folder tells a moved repository from an unrelated one by.
final class GitRootCommitTests {
    let base: URL
    let git = GitClient()

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "GitRootCommitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    @Test func clonesShareTheirRootsAndUnrelatedRepositoriesDoNot() async throws {
        let original = try makeRepository("original")
        let clone = base.appending(path: "clone")
        try sh(["clone", "-q", original.path, clone.path], in: base)
        let unrelated = try makeRepository("unrelated")

        let roots = try #require(await git.rootCommits(in: original))
        #expect(roots.count == 1)
        #expect(await git.rootCommits(in: clone) == roots)
        #expect(await git.rootCommits(in: unrelated) != roots)
    }

    @Test func nothingToTellWithoutCommitsOrARepository() async throws {
        let empty = base.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(await git.rootCommits(in: empty) == nil)
        try sh(["init", "-q", "-b", "main"], in: empty)
        #expect(await git.rootCommits(in: empty) == nil)
    }

    private func makeRepository(_ name: String) throws -> URL {
        let folder = base.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sh(["init", "-q", "-b", "main"], in: folder)
        try "\(name)\n".write(to: folder.appending(path: "README"), atomically: true, encoding: .utf8)
        try sh(["add", "README"], in: folder)
        try sh(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "-m", name], in: folder)
        return folder
    }

    private func sh(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
        }
    }
}
