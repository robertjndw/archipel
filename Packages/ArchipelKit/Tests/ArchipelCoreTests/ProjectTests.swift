import Foundation
import Testing
@testable import ArchipelCore

struct ProjectTests {
    @Test func projectsSavedBeforeIdentityFieldsStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"app","folderURL":"file:///code/app/","worktrees":[]}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.tint == nil)
        #expect(project.icon == .automatic)
        #expect(project.worktreesDirectory == nil)
        #expect(project.baseBranch == nil)
    }

    @Test func identityRoundTrips() throws {
        var project = Project(name: "app", folderURL: URL(fileURLWithPath: "/code/app"))
        project.tint = .teal
        project.icon = .symbol("hammer")
        project.worktreesDirectory = URL(fileURLWithPath: "/code/wt", isDirectory: true)
        project.baseBranch = "origin/main"
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)

        project.icon = .image(URL(fileURLWithPath: "/code/app/logo.png"))
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)) == project)
    }
}
