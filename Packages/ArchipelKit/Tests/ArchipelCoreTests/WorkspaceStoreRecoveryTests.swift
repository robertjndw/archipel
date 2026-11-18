import Foundation
import Synchronization
import Testing
@testable import ArchipelCore

/// What load and save do with a workspace file that is damaged, unreadable or written concurrently.
/// Every test works in its own temp folder.
final class WorkspaceStoreRecoveryTests {
    let folder: URL
    let url: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archipel-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        url = folder.appending(path: "workspace.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        // Put permissions back first, or the folder cannot be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func emptyFileFromAnInterruptedWriteIsQuarantined() throws {
        try Data().write(to: url)
        let backup = try quarantinedBackup { try WorkspaceStore(fileURL: url).load() }
        #expect(try Data(contentsOf: backup).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func schemaVersionOfTheWrongTypeIsQuarantined() throws {
        try Data(#"{"schemaVersion": "3", "islands": []}"#.utf8).write(to: url)
        _ = try quarantinedBackup { try WorkspaceStore(fileURL: url).load() }
    }

    @Test func quarantinedCopySurvivesTheNextSave() throws {
        let original = Data("{ \"schemaVersion\": 3, \"islands\": [ truncated".utf8)
        try original.write(to: url)
        let store = WorkspaceStore(fileURL: url)
        let backup = try quarantinedBackup { try store.load() }

        var fresh = try store.load()
        fresh.addProject(makeProject("after"), to: fresh.islands[0].id)
        try store.save(fresh)

        #expect(try Data(contentsOf: backup) == original)
        #expect(try store.load() == fresh)
    }

    @Test func unreadableFileIsLeftAloneAndNotQuarantined() throws {
        var ws = Workspace()
        ws.addProject(makeProject(), to: ws.islands[0].id)
        let store = WorkspaceStore(fileURL: url)
        try store.save(ws)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        // Not a LoadError: the file is fine, it just cannot be read right now, and moving it aside
        // would make the next save replace a perfectly good workspace.
        #expect {
            try store.load()
        } throws: { error in
            !(error is WorkspaceStore.LoadError)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["workspace.json"])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try store.load() == ws)
    }

    @Test func folderInPlaceOfTheFileIsNotTakenForMissing() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // A missing file means a first launch with an empty workspace; this is something else.
        #expect(throws: (any Error).self) { try WorkspaceStore(fileURL: self.url).load() }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func concurrentSavesLeaveOneWholeFileAndNoLeftovers() throws {
        let store = WorkspaceStore(fileURL: url)
        let candidates = (0..<8).map { index in
            var ws = Workspace()
            ws.addProject(makeProject("p\(index)"), to: ws.islands[0].id)
            return ws
        }
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            do {
                try store.save(candidates[index % candidates.count])
            } catch {
                failures.withLock { $0 += 1 }
            }
        }

        #expect(failures.withLock { $0 } == 0)
        // Each save replaces the file in one rename, so whichever came last is there in full.
        #expect(candidates.contains(try store.load()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["workspace.json"])
    }

    // MARK: Helpers

    private func quarantinedBackup(_ load: () throws -> Workspace, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        do {
            _ = try load()
        } catch WorkspaceStore.LoadError.quarantined(let backup) {
            #expect(backup.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL, sourceLocation: sourceLocation)
            return backup
        }
        Issue.record("expected the file to be quarantined", sourceLocation: sourceLocation)
        throw UnexpectedNil()
    }
}
