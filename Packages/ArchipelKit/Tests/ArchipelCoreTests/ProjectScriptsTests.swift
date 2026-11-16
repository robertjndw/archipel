import Foundation
import Testing
@testable import ArchipelCore

struct ProjectScriptsTests {
    @Test func roundTrip() throws {
        var project = makeProject("p")
        project.scripts = ProjectScripts(setup: "npm install", run: "npm run dev")
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.scripts.setup == "npm install")
    }

    @Test func projectJSONWithoutScriptsDecodesAsEmpty() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"old","folderURL":"file:///tmp/old","isExpanded":false,"worktrees":[]}
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.scripts == ProjectScripts())
        #expect(project.scripts.isEmpty)
        #expect(!project.isExpanded)
    }

    @Test func partialScriptsObjectDecodes() throws {
        let scripts = try JSONDecoder().decode(ProjectScripts.self, from: Data(#"{"run":"make"}"#.utf8))
        #expect(scripts.setup == "")
        #expect(scripts.run == "make")
    }

    @Test func emptyAndBlankScriptsHaveNoCommand() {
        let scripts = ProjectScripts(setup: "", run: "  \n\t\n ")
        #expect(scripts.setupCommand == nil)
        #expect(scripts.runCommand == nil)
        #expect(scripts.isEmpty)
    }

    @Test func commandTrimsSurroundingBlankLinesOnly() {
        let scripts = ProjectScripts(setup: "\n\n  \ncp .env.example .env\n  npm install\n\n \n", run: "npm run dev")
        #expect(scripts.setupCommand == "cp .env.example .env\n  npm install")
        #expect(scripts.runCommand == "npm run dev")
        #expect(!scripts.isEmpty)
    }

    @Test func updateProjectChangesScripts() throws {
        var ws = Workspace()
        let project = makeProject("p")
        ws.addProject(project, to: ws.islands[0].id)
        ws.updateProject(id: project.id) { $0.scripts.run = "make dev" }
        #expect(ws.project(id: project.id)?.scripts.runCommand == "make dev")
        let data = try JSONEncoder().encode(ws)
        #expect(try JSONDecoder().decode(Workspace.self, from: data) == ws)
    }
}
