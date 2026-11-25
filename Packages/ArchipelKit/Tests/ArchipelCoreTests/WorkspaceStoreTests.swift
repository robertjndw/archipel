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

    @Test func sessionArgumentsDefaultToNoneAndRoundTrip() throws {
        let json = #"{"id": "576782B3-1F07-40B8-AED6-EE5CFAEFE199", "title": "Claude Code", "agent": "claude", "createdAt": 0}"#
        // Older workspace files don't have the key.
        #expect(try JSONDecoder().decode(Session.self, from: Data(json.utf8)).arguments == nil)

        let session = Session(title: "Claude Code (Fable)", agent: .claude, arguments: "--model fable --verbose")
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        #expect(decoded.arguments == "--model fable --verbose")
    }

    @Test func sessionScriptDefaultsToNoneAndRoundTrips() throws {
        let id = "576782B3-1F07-40B8-AED6-EE5CFAEFE199"
        func session(_ extra: String) throws -> Session {
            let json = #"{"id": "\#(id)", "title": "Run", "agent": "shell", "createdAt": 0\#(extra)}"#
            return try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        }
        // Files written before scripts were remembered have no such key.
        #expect(try session("").script == nil)
        #expect(try session(#", "script": "run""#).script == .run)
        // A kind from a later version must not make the workspace unreadable.
        #expect(try session(#", "script": "deploy""#).script == nil)

        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: url)
        var ws = Workspace()
        let p = makeProject()
        ws.addProject(p, to: ws.islands[0].id)
        let run = Session(title: "Run", hasCustomTitle: true, agent: .shell, script: .run)
        ws.addSession(run, to: p.worktrees[0].id)
        ws.addSession(makeSession(), to: p.worktrees[0].id)
        try store.save(ws)
        let loaded = try store.load()
        #expect(loaded.session(id: run.id)?.script == .run)
        #expect(loaded.allSessions.map(\.script) == [.run, nil])
    }

    @Test func sessionInterfaceDefaultsToTerminalAndRoundTrips() throws {
        let id = "576782B3-1F07-40B8-AED6-EE5CFAEFE199"
        func session(_ extra: String) throws -> Session {
            let json = #"{"id": "\#(id)", "title": "Chat", "agent": "claude", "createdAt": 0\#(extra)}"#
            return try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        }
        #expect(try session("").interface == .terminal)
        #expect(try session(#", "interface": "acp""#).interface == .acp)
        // A value from a later version must not make the workspace unreadable.
        #expect(try session(#", "interface": "voice""#).interface == .terminal)

        for interface in SessionInterface.allCases {
            let original = Session(title: "Chat", agent: .claude, interface: interface)
            let encoded = try JSONEncoder().encode(original)
            #expect(String(decoding: encoded, as: UTF8.self).contains(#""interface":"\#(interface.rawValue)""#))
            #expect(try JSONDecoder().decode(Session.self, from: encoded) == original)
        }
    }

    @Test func aWorkspaceFileWithoutSessionInterfacesStillLoads() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: url)
        var ws = Workspace()
        let p = makeProject()
        ws.addProject(p, to: ws.islands[0].id)
        ws.addSession(Session(title: "Chat", agent: .claude, interface: .acp), to: p.worktrees[0].id)
        ws.addSession(makeSession(), to: p.worktrees[0].id)
        try store.save(ws)

        // What a build from before the interface existed wrote.
        func withoutInterface(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { $0.key != "interface" }.mapValues(withoutInterface)
            }
            if let array = value as? [Any] { return array.map(withoutInterface) }
            return value
        }
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let stripped = try JSONSerialization.data(withJSONObject: withoutInterface(original))
        #expect(String(decoding: stripped, as: UTF8.self).contains("\"interface\"") == false)
        try stripped.write(to: url)

        let loaded = try store.load()
        #expect(loaded.allSessions.map(\.interface) == [.terminal, .terminal])
        #expect(loaded.allSessions.count == 2)
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

        let store = WorkspaceStore(fileURL: url)
        let error = try #require(throws: WorkspaceStore.LoadError.self) { try store.load() }
        guard case .quarantined(let backup) = error else {
            Issue.record("Expected the file to be quarantined, got \(error)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(backup.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(backup.lastPathComponent.hasPrefix("workspace.corrupt-") && backup.pathExtension == "json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")

        // With the damaged file out of the way the app starts over, and saving is safe again.
        #expect(try store.load().islands.count == 1)
    }

    @Test func validJSONOfTheWrongShapeIsMovedAside() throws {
        let url = tempFile()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 3, "islands": "none"}"#.utf8).write(to: url)

        #expect { try WorkspaceStore(fileURL: url).load() } throws: { error in
            guard case WorkspaceStore.LoadError.quarantined = error else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func newerSchemaIsRefusedAndLeftInPlace() throws {
        let url = tempFile()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: url)

        var ws = Workspace()
        ws.addProject(makeProject(), to: ws.islands[0].id)
        ws.schemaVersion = Workspace.currentSchemaVersion + 1
        try store.save(ws)
        let written = try Data(contentsOf: url)

        #expect(throws: WorkspaceStore.LoadError.newerSchema(Workspace.currentSchemaVersion + 1)) { try store.load() }
        #expect(try Data(contentsOf: url) == written)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["workspace.json"])
    }

    @Test func newerSchemaIsRefusedEvenWhenTheRestDoesNotDecode() throws {
        let url = tempFile()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A later format is free to change any field, so only the version can be relied on.
        try Data(#"{"schemaVersion": 99, "archipelagos": []}"#.utf8).write(to: url)

        #expect(throws: WorkspaceStore.LoadError.newerSchema(99)) { try WorkspaceStore(fileURL: url).load() }
        #expect(FileManager.default.fileExists(atPath: url.path))
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
