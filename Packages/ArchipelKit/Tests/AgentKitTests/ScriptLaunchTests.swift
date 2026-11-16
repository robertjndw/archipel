import AgentKit
import Foundation
import Testing

struct ScriptLaunchTests {
    let sessionID = UUID(uuidString: "6B1D8B39-2C7C-4F5E-9A3E-0F4C3B2A1D00")!

    var context: LaunchContext {
        LaunchContext(
            archipelSessionID: sessionID,
            agentSessionID: nil,
            hookExecutableURL: URL(fileURLWithPath: "/Applications/Archipel.app/Contents/Helpers/archipel-hook"),
            socketURL: URL(fileURLWithPath: "/tmp/archipel.sock")
        )
    }

    var worktree: WorktreeEnvironment {
        WorktreeEnvironment(
            worktreePath: URL(fileURLWithPath: "/Users/me/.archipel/worktrees/app/feature", isDirectory: true),
            rootPath: URL(fileURLWithPath: "/Users/me/My Projects/app", isDirectory: true),
            branch: "feature/login"
        )
    }

    @Test func environmentVariables() {
        #expect(worktree.variables == [
            "ARCHIPEL_WORKTREE_PATH": "/Users/me/.archipel/worktrees/app/feature",
            "ARCHIPEL_ROOT_PATH": "/Users/me/My Projects/app",
            "ARCHIPEL_BRANCH": "feature/login",
        ])
    }

    @Test func branchIsLeftUnsetWhenUnknown() {
        var detached = worktree
        detached.branch = nil
        #expect(detached.variables["ARCHIPEL_BRANCH"] == nil)
        detached.branch = ""
        #expect(detached.variables["ARCHIPEL_BRANCH"] == nil)
        #expect(detached.variables.count == 2)
    }

    @Test func pathsAreDecodedAndStandardized() {
        let odd = WorktreeEnvironment(
            worktreePath: URL(fileURLWithPath: "/tmp/a b/./c/../d/", isDirectory: true),
            rootPath: URL(fileURLWithPath: "/tmp/ü", isDirectory: true),
            branch: nil
        )
        #expect(odd.variables["ARCHIPEL_WORKTREE_PATH"] == "/tmp/a b/d")
        #expect(odd.variables["ARCHIPEL_ROOT_PATH"] == "/tmp/ü")
    }

    @Test func scriptRunsAsZshProcessWithoutLoginFlag() {
        let script = "npm install\ncp \"$ARCHIPEL_ROOT_PATH/.env\" ."
        let command = ScriptLaunch.command(script: script, context: context, worktree: worktree)
        #expect(command.executable == "/bin/zsh")
        #expect(command.arguments == ["-c", script])
        #expect(command.environment["ARCHIPEL_SESSION_ID"] == sessionID.uuidString)
        #expect(command.environment["ARCHIPEL_SOCKET"] == "/tmp/archipel.sock")
        #expect(command.environment["ARCHIPEL_ROOT_PATH"] == "/Users/me/My Projects/app")
        #expect(command.environment["ARCHIPEL_BRANCH"] == "feature/login")
    }

    @Test func commandLineKeepsTheScriptOneWord() {
        let script = "echo 'it'\\''s' && printf '%s\\n' \"$HOME\"\nexit 3"
        let line = ScriptLaunch.command(script: script, context: context, worktree: worktree).shellCommandLine
        // A POSIX shell must hand zsh the script byte for byte as a single argument.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -- " + line + "; printf '%s' \"$3\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        #expect(throws: Never.self) { try process.run() }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: output, as: UTF8.self) == script)
        #expect(line.hasPrefix("/bin/zsh -c '"))
    }

    @Test func addingKeepsVariablesTheCommandSetsItself() {
        let base = LaunchCommand(executable: "codex", arguments: [], environment: ["ARCHIPEL_BRANCH": "own", "X": "1"])
        let merged = base.adding(worktree)
        #expect(merged.environment["ARCHIPEL_BRANCH"] == "own")
        #expect(merged.environment["X"] == "1")
        #expect(merged.environment["ARCHIPEL_WORKTREE_PATH"] == "/Users/me/.archipel/worktrees/app/feature")
        #expect(merged.executable == "codex")
    }

    @Test func agentLaunchesCanCarryTheWorktreeVariables() {
        let command = AgentDefinition.shell.launchCommand(for: context).adding(worktree)
        #expect(command.arguments == ["-l"])
        #expect(command.environment["ARCHIPEL_WORKTREE_PATH"] != nil)
        #expect(command.environment["ARCHIPEL_SESSION_ID"] == sessionID.uuidString)
    }
}
