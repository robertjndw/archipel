import AgentKit
import Foundation
import Testing

struct LoginShellEnvironmentTests {
    @Test func parsesNulSeparatedEntries() {
        let output = "PATH=/opt/homebrew/bin:/usr/bin\0CLAUDE_CONFIG_DIR=/Users/me/.config/claude\0EMPTY=\0MULTI=a\nb=c\0"
        #expect(LoginShellEnvironment.parse(Data(output.utf8)) == [
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "CLAUDE_CONFIG_DIR": "/Users/me/.config/claude",
            "EMPTY": "",
            "MULTI": "a\nb=c",
        ])
    }

    @Test func skipsWhatIsNotAVariable() {
        let output = "BASH_FUNC_nvm%%=() { echo; }\0noequals\0=x\01A=x\0OK_1=y\0"
        #expect(LoginShellEnvironment.parse(Data(output.utf8)) == ["OK_1": "y"])
        #expect(LoginShellEnvironment.parse(Data()).isEmpty)
    }

    /// The filter does not rely on its input having come through `parse`.
    @Test func sessionsGetOnlyVariables() {
        let exported = ["BASH_FUNC_nvm%%": "() { echo; }", "1A": "x", "": "y", "OK_1": "z"]
        #expect(LoginShellEnvironment.sessionVariables(from: exported) == ["OK_1": "z"])
    }

    @Test func sessionsGetWhatTheProfileExports() {
        let exported = [
            "PATH": "/opt/homebrew/bin", "CLAUDE_CONFIG_DIR": "/c", "CODEX_HOME": "/x", "ANTHROPIC_API_KEY": "k",
            "HTTPS_PROXY": "http://proxy:8080", "XDG_CONFIG_HOME": "/xdg", "HOME": "/Users/me", "LANG": "en_US.UTF-8",
        ]
        #expect(LoginShellEnvironment.sessionVariables(from: exported) == exported)
    }

    @Test func sessionsKeepTheirOwnTerminalAndArchipelVariables() {
        let exported = [
            "PWD": "/", "OLDPWD": "/", "SHLVL": "2", "_": "/usr/bin/env", "TERM": "dumb", "TERM_PROGRAM": "Apple_Terminal",
            "TERMINFO": "/t", "COLORTERM": "truecolor", "TMUX": "x",
            "ARCHIPEL_SESSION_ID": "another-tab", "ARCHIPEL_SOCKET": "/tmp/other.sock", "ARCHIPEL_CLAUDE_HOOKS": "settings",
            "GHOSTTY_RESOURCES_DIR": "/g", "XPC_SERVICE_NAME": "0", "__CF_USER_TEXT_ENCODING": "0x1F5:0:0",
            "DYLD_INSERT_LIBRARIES": "/lib", "EDITOR": "vim",
        ]
        #expect(LoginShellEnvironment.sessionVariables(from: exported) == ["EDITOR": "vim"])
    }

    /// The shell that is asked runs without a terminal, so `export GPG_TTY=$(tty)` in a profile
    /// yields "not a tty", and gpg in a session that inherited it cannot ask for a passphrase.
    @Test func sessionsDoNotInheritTheCaptureShellsTerminalNames() {
        let exported = ["PATH": "/usr/bin", "GPG_TTY": "not a tty", "TTY": "not a tty", "SSH_TTY": "/dev/ttys003", "GPG_AGENT_INFO": "x"]
        #expect(LoginShellEnvironment.sessionVariables(from: exported) == ["PATH": "/usr/bin", "GPG_AGENT_INFO": "x"])
    }

    @Test func theCaptureFileIsTheUsersAloneAndLeavesNothingOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A permissive umask must not widen it.
        let mask = umask(0)
        defer { umask(mask) }

        let (writing, reading) = try #require(LoginShellEnvironment.makeCaptureFile(in: directory))
        var status = stat()
        #expect(fstat(writing.fileDescriptor, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o600)
        // Its name is gone before the shell writes a secret into it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        try writing.write(contentsOf: Data("SECRET=1".utf8))
        try writing.close()
        #expect(try reading.readToEnd() == Data("SECRET=1".utf8))
    }

    @Test func noCaptureFileWhereOneCannotBeMade() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)")
        #expect(LoginShellEnvironment.makeCaptureFile(in: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
