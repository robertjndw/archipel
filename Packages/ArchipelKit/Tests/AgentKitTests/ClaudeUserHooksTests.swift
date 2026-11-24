@testable import AgentKit
import Foundation
import Testing

struct ClaudeUserHooksTests {
    let link = URL(fileURLWithPath: "/Users/me/Library/Application Support/Archipel/bin/archipel-hook")
    let socket = URL(fileURLWithPath: "/Users/me/Library/Application Support/Archipel/hook.sock")
    let devLink = URL(fileURLWithPath: "/Users/me/Library/Application Support/Archipel Dev/bin/archipel-hook")

    private func handlers(_ settings: [String: Any], event: String) -> [[String: Any]] {
        let groups = ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    private func userHook(_ command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command]]]
    }

    // MARK: Command

    @Test func commandQuotesPathsWithSpacesAndApostrophes() throws {
        let odd = URL(fileURLWithPath: "/Users/o'neil/My Support/bin/archipel-hook")
        let command = ClaudeUserHooks.command(link: odd, socket: URL(fileURLWithPath: "/tmp/it's here.sock"))
        #expect(command.contains(#"'/Users/o'\''neil/My Support/bin/archipel-hook' user-settings '/tmp/it'\''s here.sock'"#))
        #expect(command.hasSuffix("; exit 0"))
    }

    @Test func commandIsSilentWhenTheHelperIsMissing() throws {
        let missing = URL(fileURLWithPath: "/nonexistent dir/archipel-hook")
        let command = ClaudeUserHooks.command(link: missing, socket: socket)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["ARCHIPEL_SESSION_ID": UUID().uuidString, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(data.isEmpty)
    }

    // MARK: Merge

    @Test func installsOneGroupOnEveryEvent() throws {
        let result = try ClaudeUserHooks.installing(into: [:], link: link, socket: socket)
        let hooks = try #require(result["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(ClaudeAdapter.hookEvents))
        for event in ClaudeAdapter.hookEvents {
            let found = handlers(result, event: event)
            #expect(found.count == 1)
            #expect(found.first?["command"] as? String == ClaudeUserHooks.command(link: link, socket: socket))
            #expect(found.first?["type"] as? String == "command")
            let timeout = found.first?["timeout"] as? Int
            #expect(timeout == 5)
        }
        #expect(ClaudeUserHooks.status(of: result, link: link, socket: socket) == .installed)
    }

    @Test func keepsTheUsersOwnHooksAndKeys() throws {
        let settings: [String: Any] = [
            "model": "opus",
            "statusLine": ["type": "command", "command": "mine"],
            "permissions": ["allow": ["Bash(ls)"]],
            "hooks": ["Stop": [userHook("notify-me")], "PreCompact": [userHook("custom")]],
        ]
        let result = try ClaudeUserHooks.installing(into: settings, link: link, socket: socket)
        #expect(result["model"] as? String == "opus")
        #expect((result["statusLine"] as? [String: Any])?["command"] as? String == "mine")
        #expect(NSDictionary(dictionary: result["permissions"] as! [String: Any]).isEqual(to: settings["permissions"] as! [String: Any]))

        let stop = handlers(result, event: "Stop")
        #expect(stop.map { $0["command"] as? String }.first == "notify-me")
        #expect(stop.count == 2)
        #expect(handlers(result, event: "PreCompact").count == 1)
    }

    @Test func installingTwiceEqualsOnce() throws {
        let once = try ClaudeUserHooks.installing(into: ["model": "x"], link: link, socket: socket)
        let twice = try ClaudeUserHooks.installing(into: once, link: link, socket: socket)
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
    }

    @Test func removalTakesOnlyOurHandlers() throws {
        let shared: [String: Any] = [
            "matcher": "Bash",
            "hooks": [
                ["type": "command", "command": "theirs"],
                ["type": "command", "command": ClaudeUserHooks.command(link: link, socket: socket)],
            ],
        ]
        let settings: [String: Any] = ["effort": "high", "hooks": ["PreToolUse": [shared, userHook("other")]]]
        let installed = try ClaudeUserHooks.installing(into: settings, link: link, socket: socket)
        let removed = try ClaudeUserHooks.removing(from: installed, link: link)

        // The group we shared with the user keeps their handler and its matcher.
        let groups = try #require((removed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(groups[0]["matcher"] as? String == "Bash")
        #expect((groups[0]["hooks"] as? [[String: Any]])?.map { $0["command"] as? String } == ["theirs"])
        // Events that only had our entry are removed, and so is the hooks key once it is empty.
        #expect(Set((removed["hooks"] as! [String: Any]).keys) == ["PreToolUse"])
        #expect(removed["effort"] as? String == "high")
    }

    @Test func removalDropsEmptyHooksKey() throws {
        let installed = try ClaudeUserHooks.installing(into: ["model": "x"], link: link, socket: socket)
        let removed = try ClaudeUserHooks.removing(from: installed, link: link)
        #expect(NSDictionary(dictionary: removed).isEqual(to: ["model": "x"]))
    }

    @Test func removalLeavesEmptyUserGroupsAlone() throws {
        let settings: [String: Any] = ["hooks": ["Stop": [["hooks": [Any]()]]]]
        let removed = try ClaudeUserHooks.removing(from: settings, link: link)
        #expect(NSDictionary(dictionary: removed).isEqual(to: settings))
    }

    @Test func malformedHooksThrowInsteadOfBeingRewritten() {
        #expect(throws: ClaudeUserHooks.Failure.self) {
            try ClaudeUserHooks.installing(into: ["hooks": "nope"], link: link, socket: socket)
        }
        #expect(throws: ClaudeUserHooks.Failure.self) {
            try ClaudeUserHooks.installing(into: ["hooks": ["Stop": "nope"]], link: link, socket: socket)
        }
        #expect(throws: ClaudeUserHooks.Failure.self) {
            try ClaudeUserHooks.removing(from: ["hooks": ["Stop": ["a": 1]]], link: link)
        }
    }

    @Test func outdatedEntriesAreReplaced() throws {
        let oldSocket = URL(fileURLWithPath: "/tmp/old.sock")
        let old = try ClaudeUserHooks.installing(into: [:], link: link, socket: oldSocket)
        #expect(ClaudeUserHooks.status(of: old, link: link, socket: socket) == .outdated)

        let updated = try ClaudeUserHooks.installing(into: old, link: link, socket: socket)
        #expect(ClaudeUserHooks.status(of: updated, link: link, socket: socket) == .installed)
        for event in ClaudeAdapter.hookEvents { #expect(handlers(updated, event: event).count == 1) }
    }

    @Test func partialInstallIsOutdated() throws {
        var settings = try ClaudeUserHooks.installing(into: [:], link: link, socket: socket)
        var hooks = settings["hooks"] as! [String: Any]
        hooks["Stop"] = nil
        settings["hooks"] = hooks
        #expect(ClaudeUserHooks.status(of: settings, link: link, socket: socket) == .outdated)
        #expect(ClaudeUserHooks.status(of: [:], link: link, socket: socket) == .notInstalled)
        #expect(ClaudeUserHooks.status(of: ["hooks": [String: Any]()], link: link, socket: socket) == .notInstalled)
    }

    @Test func debugAndReleaseEntriesCoexist() throws {
        let both = try ClaudeUserHooks.installing(
            into: try ClaudeUserHooks.installing(into: [:], link: link, socket: socket),
            link: devLink,
            socket: socket
        )
        for event in ClaudeAdapter.hookEvents { #expect(handlers(both, event: event).count == 2) }
        #expect(ClaudeUserHooks.status(of: both, link: link, socket: socket) == .installed)
        #expect(ClaudeUserHooks.status(of: both, link: devLink, socket: socket) == .installed)

        let withoutDev = try ClaudeUserHooks.removing(from: both, link: devLink)
        #expect(ClaudeUserHooks.status(of: withoutDev, link: devLink, socket: socket) == .notInstalled)
        #expect(ClaudeUserHooks.status(of: withoutDev, link: link, socket: socket) == .installed)
    }

    @Test func launchEntriesViaSettingsFlagAreNotTouched() throws {
        // `--settings` entries use the bundle path with no mode argument.
        let launch = URL(fileURLWithPath: "/Applications/Archipel.app/Contents/Helpers/archipel-hook")
        let settings: [String: Any] = ["hooks": ["Stop": [userHook(ShellQuoting.quote(launch.path))]]]
        let removed = try ClaudeUserHooks.removing(from: try ClaudeUserHooks.installing(into: settings, link: launch, socket: socket), link: launch)
        #expect(NSDictionary(dictionary: removed).isEqual(to: settings))
    }

    // MARK: settingsFile

    @Test func settingsFileHonoursConfigDirectory() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ClaudeUserHooks.settingsFile(configDirectory: "/opt/claude", home: home).path == "/opt/claude/settings.json")
        #expect(ClaudeUserHooks.settingsFile(configDirectory: "", home: home).path == "/Users/me/.claude/settings.json")
        #expect(ClaudeUserHooks.settingsFile(configDirectory: nil, home: home).path == "/Users/me/.claude/settings.json")
    }
}

/// Everything below touches the disk, always inside a throwaway directory and never the real home.
struct ClaudeUserHooksFileTests {
    let link = URL(fileURLWithPath: "/tmp/support/bin/archipel-hook")
    let socket = URL(fileURLWithPath: "/tmp/support/hook.sock")

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "claude-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func object(_ file: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    @Test func missingFileIsCreatedWithItsDirectory() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "nested/.claude/settings.json")

        #expect(try ClaudeUserHooks.status(file: file, link: link, socket: socket) == .notInstalled)
        try ClaudeUserHooks.install(file: file, link: link, socket: socket)
        #expect(try ClaudeUserHooks.status(file: file, link: link, socket: socket) == .installed)

        try ClaudeUserHooks.uninstall(file: file, link: link)
        #expect(try ClaudeUserHooks.status(file: file, link: link, socket: socket) == .notInstalled)
        #expect(try object(file).isEmpty)
    }

    @Test func uninstallDoesNotCreateAFile() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "settings.json")
        try ClaudeUserHooks.uninstall(file: file, link: link)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func invalidJSONThrowsAndLeavesTheFileUntouched() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "settings.json")
        let original = Data(#"{"model": "opus", // comment"#.utf8)
        try original.write(to: file)

        #expect(throws: ClaudeUserHooks.Failure.self) { try ClaudeUserHooks.install(file: file, link: link, socket: socket) }
        #expect(throws: ClaudeUserHooks.Failure.self) { try ClaudeUserHooks.uninstall(file: file, link: link) }
        #expect(throws: ClaudeUserHooks.Failure.self) { _ = try ClaudeUserHooks.status(file: file, link: link, socket: socket) }
        #expect(try Data(contentsOf: file) == original)

        try Data("[1, 2]".utf8).write(to: file)
        #expect(throws: ClaudeUserHooks.Failure.self) { try ClaudeUserHooks.install(file: file, link: link, socket: socket) }
        #expect(try Data(contentsOf: file) == Data("[1, 2]".utf8))
    }

    @Test func symlinkedSettingsFileStaysASymlink() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appending(path: "dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: real)
        let shown = directory.appending(path: "settings.json")
        try FileManager.default.createSymbolicLink(at: shown, withDestinationURL: real)

        try ClaudeUserHooks.install(file: shown, link: link, socket: socket)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: shown.path) == real.path)
        #expect(try object(real)["model"] as? String == "opus")
        #expect(try ClaudeUserHooks.status(file: real, link: link, socket: socket) == .installed)
    }

    @Test func permissionsSurviveTheRewrite() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "settings.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        try ClaudeUserHooks.install(file: file, link: link, socket: socket)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func backupIsTakenOnceAndPathsAreNotEscaped() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "settings.json")
        let original = Data(#"{"model":"opus"}"#.utf8)
        try original.write(to: file)

        try ClaudeUserHooks.install(file: file, link: link, socket: socket)
        let backup = directory.appending(path: "settings.json.archipel-backup")
        #expect(try Data(contentsOf: backup) == original)

        try ClaudeUserHooks.install(file: file, link: link, socket: URL(fileURLWithPath: "/tmp/other.sock"))
        #expect(try Data(contentsOf: backup) == original)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(#"\/"#))
        #expect(text.hasSuffix("\n"))
    }

    @Test func unchangedInstallDoesNotRewrite() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "settings.json")
        try ClaudeUserHooks.install(file: file, link: link, socket: socket)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        Thread.sleep(forTimeInterval: 0.05)
        try ClaudeUserHooks.install(file: file, link: link, socket: socket)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == before)
    }
}
