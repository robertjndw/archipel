import Foundation
import Testing
@testable import ArchipelCore

struct WorktreeLocationEdgeCaseTests {
    let root = URL(fileURLWithPath: "/tmp/worktrees", isDirectory: true)

    private func project(_ name: String, at folder: String, worktreeFolders: [String] = []) -> Project {
        Project(name: name, folderURL: URL(fileURLWithPath: folder), worktrees: [
            Worktree(path: URL(fileURLWithPath: folder), isMain: true),
        ] + worktreeFolders.map { Worktree(path: URL(fileURLWithPath: $0, isDirectory: true), branch: "b") })
    }

    @Test func projectNamesLoseOnlyWhatBreaksAPath() {
        #expect(WorktreeLocation.folderName(forProject: "") == "project")
        #expect(WorktreeLocation.folderName(forProject: "...") == "project")
        #expect(WorktreeLocation.folderName(forProject: " .. ") == "project")
        #expect(WorktreeLocation.folderName(forProject: "a:b") == "a-b")
        #expect(WorktreeLocation.folderName(forProject: "nul\u{0}del\u{7F}") == "nul-del-")
        #expect(WorktreeLocation.folderName(forProject: "\ttabbed") == "-tabbed")
        #expect(WorktreeLocation.folderName(forProject: "  padded  ") == "padded")
        #expect(WorktreeLocation.folderName(forProject: "crlf\r\nname") == "crlf-name")
        // Spaces, dots and anything printable stay, so an existing folder keeps matching.
        #expect(WorktreeLocation.folderName(forProject: "~ caf\u{e9} .app") == "~ caf\u{e9} .app")
        #expect(WorktreeLocation.folderName(forProject: "...hidden") == "...hidden")
    }

    @Test func threeProjectsOfOneNameKeepTheirFoldersInAnyOrder() {
        let a = project("app", at: "/a/app", worktreeFolders: ["/tmp/worktrees/app/x"])
        let b = project("app", at: "/b/app", worktreeFolders: ["/tmp/worktrees/app-2/x"])
        let c = project("app", at: "/c/app", worktreeFolders: ["/tmp/worktrees/app-3/x"])
        let fresh = project("app", at: "/d/app")
        for projects in [[a, b, c, fresh], [fresh, c, b, a], [b, fresh, a, c]] {
            let folders = [a, b, c, fresh].map { WorktreeLocation.defaultParentFolder(for: $0, defaultRoot: root, among: projects).path }
            #expect(folders == ["/tmp/worktrees/app", "/tmp/worktrees/app-2", "/tmp/worktrees/app-3", "/tmp/worktrees/app-4"])
        }
    }

    @Test func projectNamedLikeANumberedFolderDoesNotTakeIt() {
        let first = project("app", at: "/a/app", worktreeFolders: ["/tmp/worktrees/app/x"])
        let second = project("app", at: "/b/app", worktreeFolders: ["/tmp/worktrees/app-2/x"])
        let literal = project("app-2", at: "/c/app-2")
        let projects = [first, second, literal]
        #expect(WorktreeLocation.defaultParentFolder(for: second, defaultRoot: root, among: projects).path == "/tmp/worktrees/app-2")
        #expect(WorktreeLocation.defaultParentFolder(for: literal, defaultRoot: root, among: projects).path == "/tmp/worktrees/app-2-2")
    }

    @Test func folderMatchingIgnoresCaseAndTrailingSlashes() {
        let rootWithSlash = URL(fileURLWithPath: "/tmp/worktrees/", isDirectory: true)
        // A folder git reports as APP-2 is the same folder as app-2 on the default file system.
        let owner = project("app", at: "/a/app", worktreeFolders: ["/tmp/worktrees/APP-2/x/"])
        let other = project("App", at: "/b/app", worktreeFolders: ["/tmp/worktrees/app/x"])
        let projects = [owner, other]
        #expect(WorktreeLocation.defaultParentFolder(for: owner, defaultRoot: rootWithSlash, among: projects).path.lowercased() == "/tmp/worktrees/app-2")
        #expect(WorktreeLocation.defaultParentFolder(for: other, defaultRoot: rootWithSlash, among: projects).path == "/tmp/worktrees/App")
        let newcomer = project("APP", at: "/c/app")
        #expect(WorktreeLocation.defaultParentFolder(for: newcomer, defaultRoot: root, among: projects + [newcomer]).path == "/tmp/worktrees/APP-3")
    }

    @Test func branchFolderNeverLeavesTheProjectFolder() {
        // Only names git accepts as branches; "." and ".." are not among them.
        for branch in ["../../etc", "a/../../b", "/abs", "x\ny", "feat:colon", "a..b", "x/.hidden"] {
            let path = WorktreeLocation.path(for: project("app", at: "/a/app"), branch: branch, defaultRoot: root)
            #expect(path.deletingLastPathComponent().path == "/tmp/worktrees/app", "branch \(branch)")
            #expect(path.standardizedFileURL.deletingLastPathComponent().path == "/tmp/worktrees/app", "branch \(branch)")
        }
    }

    @Test func worktreeRecordedThroughASymlinkStillClaimsItsFolder() {
        // /tmp is a symlink to /private/tmp, and `git worktree list` reports the resolved path,
        // which is what discovered worktrees are stored with.
        let discovered = project("app", at: "/a/app", worktreeFolders: ["/private/tmp/worktrees/app/x"])
        let other = project("app", at: "/b/app")
        let projects = [discovered, other]

        // Compared as written, the folder git reports and the configured root would never match,
        // and the second project would be handed the folder the first one already uses.
        #expect(WorktreeLocation.defaultParentFolder(for: other, defaultRoot: root, among: projects).path == "/tmp/worktrees/app-2")
    }

    @Test func aWorktreeRenamedInPlaceIsFoundAndADeletedOneIsNot() throws {
        let base = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
            .appending(path: "ArchipelMoved-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appending(path: "repo", directoryHint: .isDirectory)
        let worktrees = base.appending(path: "wt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)

        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        }
        try git("init", "-q", "-b", "main")
        try git("commit", "-q", "--allow-empty", "-m", "init")
        let renamed = worktrees.appending(path: "renamed", directoryHint: .isDirectory)
        let deleted = worktrees.appending(path: "deleted", directoryHint: .isDirectory)
        try git("worktree", "add", "-q", "-b", "renamed", renamed.path)
        try git("worktree", "add", "-q", "-b", "deleted", deleted.path)

        // In place, neither has gone anywhere. Its own registration points at itself, not at a neighbour.
        #expect(WorktreeLocation.movedWorktree(from: renamed) == nil)

        let newName = worktrees.appending(path: "renamed-old", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: renamed, to: newName)
        try FileManager.default.removeItem(at: deleted)

        // Both read as gone by their surroundings, which is why the neighbours are looked at.
        #expect(WorktreeLocation.isProvablyGone(renamed))
        #expect(WorktreeLocation.isProvablyGone(deleted))
        #expect(WorktreeLocation.movedWorktree(from: renamed)?.path == newName.standardizedFileURL.path)
        #expect(WorktreeLocation.movedWorktree(from: deleted) == nil)
        // The main checkout has a `.git` folder, not a pointer, and is never taken for a moved worktree.
        #expect(WorktreeLocation.movedWorktree(from: base.appending(path: "gone")) == nil)
    }

    @Test func registrationsTellWhereAWorktreeWasAndWhatARepositoryHas() throws {
        let base = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
            .appending(path: "ArchipelLocate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        }
        try git("init", "-q", "-b", "main")
        try git("commit", "-q", "--allow-empty", "-m", "init")
        let feature = base.appending(path: "feature", directoryHint: .isDirectory)
        try git("worktree", "add", "-q", "-b", "feature", feature.path)

        let moved = base.appending(path: "elsewhere/feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: feature, to: moved)
        // Until it is repaired, the registration still names the folder it was made in.
        #expect(WorktreeLocation.recordedFolder(ofWorktreeAt: moved).map { WorktreeLocation.isSameFolder($0, feature) } == true)
        #expect(WorktreeLocation.recordedFolder(ofWorktreeAt: repo) == nil)
        #expect(WorktreeLocation.recordedFolder(ofWorktreeAt: base) == nil)

        // The main checkout still lists the worktree where it was made, wherever the checkout goes.
        let movedRepo = base.appending(path: "renamed-repo", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: repo, to: movedRepo)
        let registered = WorktreeLocation.registeredWorktreeFolders(ofRepositoryAt: movedRepo)
        #expect(registered.count == 1)
        #expect(registered.first.map { WorktreeLocation.isSameFolder($0, feature) } == true)
        #expect(WorktreeLocation.registeredWorktreeFolders(ofRepositoryAt: moved).isEmpty)
    }

    @Test func provablyGoneNormalizesThePathFirst() {
        func gone(_ path: String, existing: Set<String>) -> Bool {
            WorktreeLocation.isProvablyGone(URL(fileURLWithPath: path)) { existing.contains($0) }
        }
        #expect(!gone("/", existing: []))
        #expect(gone("/Users/me/wt/app/../app/fix/", existing: ["/Users/me/wt/app"]))
        #expect(!gone("/Volumes/Work/", existing: ["/Volumes"]))
        #expect(!gone("/Volumes/Work/./fix", existing: ["/Volumes"]))
        #expect(gone("/Volumes/Work/./fix", existing: ["/Volumes/Work"]))
    }

    @Test func provablyGoneOnDiskFollowsSymlinkedParents() throws {
        let base = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
            .appending(path: "ArchipelGoneLink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let real = base.appending(path: "real", directoryHint: .isDirectory)
        let link = base.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(WorktreeLocation.isProvablyGone(link.appending(path: "fix", directoryHint: .isDirectory)))
        try FileManager.default.createDirectory(at: real.appending(path: "fix"), withIntermediateDirectories: true)
        #expect(!WorktreeLocation.isProvablyGone(link.appending(path: "fix", directoryHint: .isDirectory)))

        // A link whose target went away, as with an unmounted disk behind it, proves nothing.
        try FileManager.default.removeItem(at: real)
        #expect(!WorktreeLocation.isProvablyGone(link.appending(path: "fix", directoryHint: .isDirectory)))
    }
}
