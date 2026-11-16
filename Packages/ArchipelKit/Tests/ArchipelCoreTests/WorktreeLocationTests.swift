import Foundation
import Testing
@testable import ArchipelCore

struct WorktreeLocationTests {
    let root = URL(fileURLWithPath: "/tmp/worktrees", isDirectory: true)

    @Test func branchBecomesOneFolder() {
        #expect(WorktreeLocation.folderName(forBranch: "feature/login page") == "feature-login-page")
        #expect(WorktreeLocation.folderName(forBranch: "fix_1.2-rc") == "fix_1.2-rc")
    }

    @Test func defaultRootNestsByProject() {
        let project = Project(name: "app", folderURL: URL(fileURLWithPath: "/code/app"))
        let path = WorktreeLocation.path(for: project, branch: "feature/x", defaultRoot: root)
        #expect(path.path == "/tmp/worktrees/app/feature-x")
    }

    @Test func customFolderHoldsWorktreesDirectly() {
        let custom = URL(fileURLWithPath: "/code/app-worktrees", isDirectory: true)
        let project = Project(name: "app", folderURL: URL(fileURLWithPath: "/code/app"), worktreesDirectory: custom)
        let path = WorktreeLocation.path(for: project, branch: "feature/x", defaultRoot: root)
        #expect(path.path == "/code/app-worktrees/feature-x")
    }
}
