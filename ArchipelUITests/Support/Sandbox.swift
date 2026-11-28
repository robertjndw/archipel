import ArchipelCore
import Foundation
import XCTest

/// Everything one test may touch on disk: the app's support folder, a stand-in home for the
/// processes the app starts, the folder new worktrees go to, and the fixture repositories.
struct Sandbox {
    let root: URL

    /// Short on purpose: the hook socket lives in here, and a Unix socket path is limited to about
    /// 100 bytes.
    var support: URL { root.appending(path: "s", directoryHint: .isDirectory) }
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    var worktreesRoot: URL { root.appending(path: "worktrees", directoryHint: .isDirectory) }
    var bin: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
    var workspaceFile: URL { support.appending(path: "workspace.json") }

    init() throws {
        // Under /private/tmp and not the runner's own temporary folder, whose path is long enough
        // to push the socket over the limit. Spelled with /private because git reports worktree
        // paths with symlinks followed, and the tests compare against those.
        let name = "archipel-e2e-" + UUID().uuidString.prefix(8).lowercased()
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appending(path: name, directoryHint: .isDirectory)
        for folder in [support, home, worktreesRoot, bin] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The app asks `$SHELL -l` for the PATH its sessions get, and sh reads this file as the
        // home's profile. Putting the sandbox first lets a test stand in for an agent's executable.
        try "export PATH=\"\(bin.path):$PATH\"\n".write(to: home.appending(path: ".profile"), atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Puts an executable named like an agent first on the PATH of the app's sessions. It writes
    /// down how it was started and then stays alive, as an agent waiting for input would. Without
    /// this, starting an agent session would run whatever is installed on the machine.
    func installAgentStub(named name: String) throws -> URL {
        let record = root.appending(path: "\(name)-launch.txt")
        let script = """
            #!/bin/sh
            {
              echo "session=$ARCHIPEL_SESSION_ID"
              echo "socket=$ARCHIPEL_SOCKET"
              echo "cwd=$PWD"
              for argument in "$@"; do echo "argument=$argument"; done
            } > '\(record.path)'
            while :; do sleep 1; done

            """
        let executable = bin.appending(path: name)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return record
    }

    /// A repository with one commit on `main`, identity configured locally so commits made by the
    /// app do not depend on the machine's git configuration.
    func makeRepository(named name: String) throws -> FixtureRepository {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let repository = FixtureRepository(url: url, home: home)
        try repository.git("init", "--initial-branch=main")
        try repository.git("config", "user.name", "Archipel Tests")
        try repository.git("config", "user.email", "tests@archipel.invalid")
        try repository.git("config", "commit.gpgsign", "false")
        try repository.write("README.md", "# \(name)\n")
        try repository.write("notes.txt", "first line\n")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "initial commit")
        return repository
    }

    /// Writes the workspace file the app loads at launch, through the app's own model and store so
    /// the tests never spell out its schema.
    func seed(_ workspace: Workspace) throws {
        try WorkspaceStore(fileURL: workspaceFile).save(workspace)
    }

    /// The workspace as the app last saved it.
    func savedWorkspace() throws -> Workspace {
        try WorkspaceStore(fileURL: workspaceFile).load()
    }
}

struct FixtureRepository {
    let url: URL
    let home: URL

    struct GitFailure: Error, CustomStringConvertible {
        let description: String
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try git(arguments, in: url)
    }

    @discardableResult
    func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        // The same blinkers the app under test gets: neither the user's nor the system's git
        // configuration may decide how a fixture repository behaves.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read before waiting: a full pipe would otherwise block git forever.
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFailure(description: "git \(arguments.joined(separator: " ")) failed: \(errorText)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    /// A workspace with this repository as its only project and the main checkout selected.
    /// `linkedWorktrees` are folders made with `addWorktree(branch:in:)`.
    func workspace(projectName: String? = nil, sessions: [Session] = [], linkedWorktrees: [Worktree] = []) -> Workspace {
        let main = Worktree(path: url, branch: "main", isMain: true, sessions: sessions)
        let project = Project(name: projectName ?? url.lastPathComponent, folderURL: url, worktrees: [main] + linkedWorktrees)
        var workspace = Workspace()
        workspace.addProject(project, to: workspace.islands[0].id)
        workspace.selectWorktree(main.id)
        return workspace
    }

    /// Creates a branch with a linked worktree the way `git worktree add` on the command line would,
    /// for tests that start with one already in the sidebar. With `placeholder` the app is told the
    /// name was generated, as for a worktree it started without a branch, which makes the names
    /// of these tests deterministic.
    func addWorktree(branch: String, in folder: URL, placeholder: Bool = false) throws -> Worktree {
        let path = folder.appending(path: branch, directoryHint: .isDirectory)
        try git("worktree", "add", "-b", branch, path.path)
        return Worktree(path: path, branch: branch, placeholderBranch: placeholder ? branch : nil)
    }

    var currentBranch: String {
        get throws { try git("rev-parse", "--abbrev-ref", "HEAD") }
    }

    var branches: [String] {
        get throws { try git("branch", "--format=%(refname:short)").split(separator: "\n").map(String.init) }
    }

    /// The folders git has registered as worktrees of this repository, main checkout included.
    var worktreePaths: [String] {
        get throws {
            try git("worktree", "list", "--porcelain").split(separator: "\n")
                .filter { $0.hasPrefix("worktree ") }
                .map { String($0.dropFirst("worktree ".count)) }
        }
    }
}

extension Session {
    static func shell(_ title: String = "Shell") -> Session {
        Session(title: title, agent: AgentKind(rawValue: "shell"))
    }
}
