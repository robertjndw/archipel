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

    @Test func projectNameStaysOneFolderInsideTheRoot() {
        #expect(WorktreeLocation.folderName(forProject: "..") == "project")
        #expect(WorktreeLocation.folderName(forProject: ".") == "project")
        #expect(WorktreeLocation.folderName(forProject: "  ") == "project")
        #expect(WorktreeLocation.folderName(forProject: "a/b") == "a-b")
        #expect(WorktreeLocation.folderName(forProject: "../../etc") == "..-..-etc")
        #expect(WorktreeLocation.folderName(forProject: "line\nbreak") == "line-break")
        // Names that were fine as a folder keep it, so existing worktrees and new ones stay together.
        #expect(WorktreeLocation.folderName(forProject: "My App (v2)") == "My App (v2)")

        for name in ["..", "a/b", "../../etc"] {
            let project = Project(name: name, folderURL: URL(fileURLWithPath: "/code/app"))
            let folder = WorktreeLocation.defaultParentFolder(for: project, defaultRoot: root).standardizedFileURL
            #expect(folder.deletingLastPathComponent().path == "/tmp/worktrees")
        }
    }

    @Test func secondProjectWithTheSameNameGetsItsOwnFolder() {
        let existing = Worktree(path: URL(fileURLWithPath: "/tmp/worktrees/app/fix", isDirectory: true), branch: "fix")
        let first = Project(name: "app", folderURL: URL(fileURLWithPath: "/code/app"), worktrees: [
            Worktree(path: URL(fileURLWithPath: "/code/app"), isMain: true), existing,
        ])
        var second = Project(name: "App", folderURL: URL(fileURLWithPath: "/work/app"), worktrees: [
            Worktree(path: URL(fileURLWithPath: "/work/app"), isMain: true),
        ])
        // The order of the projects must not matter, or reordering the sidebar would swap the folders.
        for projects in [[first, second], [second, first]] {
            #expect(WorktreeLocation.path(for: first, branch: "x", defaultRoot: root, among: projects).path == "/tmp/worktrees/app/x")
            #expect(WorktreeLocation.path(for: second, branch: "x", defaultRoot: root, among: projects).path == "/tmp/worktrees/App-2/x")
        }

        // Once it has a worktree there, the folder stays its own, whatever the other project does.
        second.worktrees.append(Worktree(path: URL(fileURLWithPath: "/tmp/worktrees/App-2/x", isDirectory: true), branch: "x"))
        var renamed = first
        renamed.name = "other"
        #expect(WorktreeLocation.defaultParentFolder(for: second, defaultRoot: root, among: [renamed, second]).path == "/tmp/worktrees/App-2")
        // The renamed project left worktrees behind in the old folder, which still must not be shared.
        let third = Project(name: "app", folderURL: URL(fileURLWithPath: "/else/app"))
        #expect(WorktreeLocation.defaultParentFolder(for: third, defaultRoot: root, among: [renamed, second, third]).path == "/tmp/worktrees/app-3")
    }

    @Test func projectKeepsItsNumberedFolderWhenLowerNumbersAreFreeAgain() {
        // Three projects named "app" got app, app-2 and app-3. The first two were removed, their
        // folders stayed, and nothing in the workspace claims them any more.
        let third = Project(name: "app", folderURL: URL(fileURLWithPath: "/else/app"), worktrees: [
            Worktree(path: URL(fileURLWithPath: "/else/app"), isMain: true),
            Worktree(path: URL(fileURLWithPath: "/tmp/worktrees/app-3/fix", isDirectory: true), branch: "fix"),
        ])
        #expect(WorktreeLocation.path(for: third, branch: "x", defaultRoot: root, among: [third]).path == "/tmp/worktrees/app-3/x")

        // Worktrees elsewhere, or in a folder that only starts with the name, are no claim on a numbered folder.
        let elsewhere = Project(name: "app", folderURL: URL(fileURLWithPath: "/else/app"), worktrees: [
            Worktree(path: URL(fileURLWithPath: "/tmp/worktrees/app-3b/fix", isDirectory: true), branch: "fix"),
            Worktree(path: URL(fileURLWithPath: "/tmp/worktrees/application/fix", isDirectory: true), branch: "fix"),
            Worktree(path: URL(fileURLWithPath: "/other/app-2/fix", isDirectory: true), branch: "fix"),
        ])
        #expect(WorktreeLocation.defaultParentFolder(for: elsewhere, defaultRoot: root, among: [elsewhere]).path == "/tmp/worktrees/app")
    }

    @Test func missingFolderIsOnlyGoneWhenItsSurroundingsAreThere() {
        func gone(_ path: String, existing: Set<String>) -> Bool {
            WorktreeLocation.isProvablyGone(URL(fileURLWithPath: path, isDirectory: true)) { existing.contains($0) }
        }
        // Deleted by hand: the folder that held it is still there.
        #expect(gone("/Users/me/worktrees/app/fix", existing: ["/Users/me/worktrees/app"]))
        #expect(!gone("/Users/me/worktrees/app/fix", existing: ["/Users/me/worktrees/app", "/Users/me/worktrees/app/fix"]))
        // The whole tree is missing, as on a home folder or disk image that is not attached.
        #expect(!gone("/Users/me/worktrees/app/fix", existing: []))
        // An unmounted volume takes its folder under /Volumes along.
        #expect(!gone("/Volumes/Work/worktrees/fix", existing: ["/Volumes"]))
        #expect(gone("/Volumes/Work/worktrees/fix", existing: ["/Volumes", "/Volumes/Work", "/Volumes/Work/worktrees"]))
        #expect(!gone("/Volumes/Work/worktrees/fix", existing: ["/Volumes", "/Volumes/Work"]))
        // At the top of a disk the parent is /Volumes, which proves nothing.
        #expect(!gone("/Volumes/Work", existing: ["/Volumes"]))
        #expect(gone("/Volumes/Work/fix", existing: ["/Volumes", "/Volumes/Work"]))
    }

    @Test func missingFolderOnDisk() throws {
        let parent = URL.temporaryDirectory.appending(path: "ArchipelGone-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(WorktreeLocation.isProvablyGone(parent.appending(path: "fix", directoryHint: .isDirectory)))
        #expect(!WorktreeLocation.isProvablyGone(parent))
        #expect(!WorktreeLocation.isProvablyGone(parent.appending(path: "missing/fix", directoryHint: .isDirectory)))
    }

    @Test func sameNameWithACustomFolderDoesNotCollide() {
        let custom = Project(
            name: "app", folderURL: URL(fileURLWithPath: "/code/app"),
            worktreesDirectory: URL(fileURLWithPath: "/code/app-worktrees", isDirectory: true)
        )
        let plain = Project(name: "app", folderURL: URL(fileURLWithPath: "/work/app"))
        #expect(WorktreeLocation.defaultParentFolder(for: plain, defaultRoot: root, among: [custom, plain]).path == "/tmp/worktrees/app")
    }
}
