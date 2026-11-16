import Foundation
import Testing
@testable import ArchipelCore

struct WorkspaceStoreTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("archipel-tests-\(UUID().uuidString)")
            .appendingPathComponent("nested/workspace.json")
    }

    @Test func roundTrip() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: url)

        var ws = Workspace()
        let p = makeProject()
        ws.addProject(p, to: ws.islands[0].id)
        let extra = makeWorktree("wt", branch: "feat/x")
        ws.addWorktree(extra, to: p.id)
        var s = makeSession()
        s.agentSessionID = "abc"
        s.agentTitle = "Fix login"
        s.hasCustomTitle = true
        ws.addSession(s, to: extra.id)
        let file = try ws.openTab(.file(URL(fileURLWithPath: "/tmp/a.swift")), in: extra.id, preview: true).unwrapped()
        _ = ws.splitTab(id: file)

        try store.save(ws)
        #expect(try store.load() == ws)
        #expect(ws.schemaVersion == 3)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n"))
    }

    @Test func dismissedWorktreePathsDefaultToEmptyAndRoundTrip() throws {
        let json = """
        {"id": "FC22F8C5-F068-43A6-B99B-C507CA7A2550", "name": "demo", "folderURL": "file:///tmp/demo/", "worktrees": []}
        """
        let decoded = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(decoded.dismissedWorktreePaths.isEmpty)

        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: url)
        var ws = Workspace()
        let p = makeProject()
        ws.addProject(p, to: ws.islands[0].id)
        ws.dismissWorktree(path: URL(fileURLWithPath: "/tmp/p-gone"), in: p.id)
        try store.save(ws)
        #expect(try store.load().project(id: p.id)?.dismissedWorktreePaths == ["/tmp/p-gone"])
    }

    @Test func missingFileGivesDefault() throws {
        let store = WorkspaceStore(fileURL: tempFile())
        let ws = try store.load()
        #expect(ws.islands.map(\.name) == ["Personal"])
    }

    @Test func corruptFileIsMovedAside() throws {
        let url = tempFile()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        let ws = try WorkspaceStore(fileURL: url).load()
        #expect(ws.islands.count == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let moved = try #require(names.first { $0.hasPrefix("workspace.corrupt-") && $0.hasSuffix(".json") })
        #expect(try String(contentsOf: dir.appendingPathComponent(moved), encoding: .utf8) == "{ not json")
    }

    @Test func migratesFirstFormat() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let island = "C0A24DDB-AC7F-4F96-A41B-4D2D5DD6C202"
        let shell = "FD3B68A0-A5E3-48CC-AC8C-4C1FF61D4FB6"
        let v1 = """
        {
          "islands": [{
            "id": "\(island)", "name": "Personal", "symbol": "house", "tint": "blue",
            "projects": [{
              "id": "FC22F8C5-F068-43A6-B99B-C507CA7A2550", "name": "demo", "folderURL": "file:///tmp/demo/",
              "sessions": [
                {"id": "576782B3-1F07-40B8-AED6-EE5CFAEFE199", "title": "Claude Code", "agent": "claude",
                 "agentSessionID": "abc", "createdAt": "2026-11-13T17:38:55Z", "workingDirectory": "file:///tmp/demo/"},
                {"id": "\(shell)", "title": "Shell", "agent": "shell",
                 "createdAt": "2026-11-13T17:42:29Z", "workingDirectory": "file:///tmp/wt/",
                 "worktree": {"path": "file:///tmp/wt/", "branch": "feat/x"}}
              ]
            }]
          }],
          "schemaVersion": 1,
          "selectedIslandID": "\(island)",
          "selectedSessionIDByIsland": ["\(island)", "\(shell)"]
        }
        """
        try Data(v1.utf8).write(to: url)

        let ws = try WorkspaceStore(fileURL: url).load()
        #expect(ws.schemaVersion == Workspace.currentSchemaVersion)
        let project = try #require(ws.islands.first?.projects.first)
        #expect(project.worktrees.count == 2)
        #expect(project.worktrees[0].isMain)
        #expect(project.worktrees[0].sessions.map(\.title) == ["Claude Code"])
        #expect(project.worktrees[0].sessions[0].agentSessionID == "abc")
        #expect(project.worktrees[1].branch == "feat/x")
        #expect(ws.selectedWorktreeID == project.worktrees[1].id)
        #expect(ws.focusedSessionID(in: project.worktrees[1].id) == UUID(uuidString: shell))
        for worktree in project.worktrees {
            #expect(worktree.panes.count == 1)
            #expect(worktree.panes[0].tabs.map(\.content) == worktree.sessions.map { .session($0.id) })
        }
        // Nothing was quarantined: the old file is still the workspace file.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
