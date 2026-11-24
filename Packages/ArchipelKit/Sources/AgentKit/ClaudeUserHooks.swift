import Foundation

/// Opt-in hook entries in the user's own Claude settings, so a Claude typed by hand into a shell
/// tab reports to Archipel.
public enum ClaudeUserHooks {
    /// First argument that puts `archipel-hook` into its user-settings mode. Keep in step with
    /// archipel-hook/main.swift, which has no dependencies and so repeats the literal.
    public static let modeArgument = "user-settings"
    /// Set to `launchedByArchipelValue` in every Claude Archipel starts itself. Those already carry
    /// their hooks through `--settings`, so the user-settings entries stay quiet to avoid
    /// double reports. Keep in step with archipel-hook/main.swift.
    public static let launchedByArchipelVariable = "ARCHIPEL_CLAUDE_HOOKS"
    public static let launchedByArchipelValue = "settings"

    public enum Status: Equatable, Sendable {
        case notInstalled, installed, outdated
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalidJSON(file: String)
        case notAnObject(file: String)
        case unexpectedShape(String)
        case changedWhileWriting(file: String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let file):
                "\(file) is not valid JSON, so Archipel did not change it."
            case .notAnObject(let file):
                "\(file) does not contain a JSON object, so Archipel did not change it."
            case .unexpectedShape(let key):
                "\(key) in the settings file is not in the format Claude Code expects, so Archipel did not change it."
            case .changedWhileWriting(let file):
                "\(file) changed while Archipel was updating it. Try again."
            }
        }
    }

    /// Runs for every Claude on the Mac, so the environment checks keep it from doing anything
    /// outside an Archipel tab. `exit 0` keeps a failing `test` from reading as a hook error.
    public static func command(link: URL, socket: URL) -> String {
        let helper = ShellQuoting.quote(link.path)
        return "test -n \"$ARCHIPEL_SESSION_ID\" && test -z \"$\(launchedByArchipelVariable)\" "
            + "&& test -x \(helper) && \(helper) \(modeArgument) \(ShellQuoting.quote(socket.path)); exit 0"
    }

    /// The Debug build ("Archipel Dev") and the release build keep their links in different
    /// support directories, so each recognises only its own entries.
    private static func isOurs(_ handler: Any, link: URL) -> Bool {
        guard let command = (handler as? [String: Any])?["command"] as? String else { return false }
        return command.contains(" \(ShellQuoting.quote(link.path)) \(modeArgument)")
    }

    public static func installing(into settings: [String: Any], link: URL, socket: URL) throws -> [String: Any] {
        var result = try removing(from: settings, link: link)
        var hooks = (result["hooks"] as? [String: Any]) ?? [:]
        let group: [String: Any] = ["hooks": [ClaudeAdapter.hookHandler(command: command(link: link, socket: socket))]]
        for event in ClaudeAdapter.hookEvents {
            hooks[event] = ((hooks[event] as? [Any]) ?? []) + [group]
        }
        result["hooks"] = hooks
        return result
    }

    public static func removing(from settings: [String: Any], link: URL) throws -> [String: Any] {
        guard let existing = settings["hooks"] else { return settings }
        guard var hooks = existing as? [String: Any] else { throw Failure.unexpectedShape("hooks") }

        for event in ClaudeAdapter.hookEvents {
            guard let value = hooks[event] else { continue }
            guard let groups = value as? [Any] else { throw Failure.unexpectedShape("hooks.\(event)") }

            var kept: [Any] = []
            var changed = false
            for group in groups {
                guard var dictionary = group as? [String: Any], let handlers = dictionary["hooks"] as? [Any] else {
                    kept.append(group)
                    continue
                }
                let remaining = handlers.filter { !isOurs($0, link: link) }
                guard remaining.count != handlers.count else {
                    kept.append(group)
                    continue
                }
                changed = true
                // Drop a group that only held our handler. A group shared with the user's handlers
                // keeps theirs.
                if !remaining.isEmpty {
                    dictionary["hooks"] = remaining
                    kept.append(dictionary)
                }
            }
            guard changed else { continue }
            hooks[event] = kept.isEmpty ? nil : kept
        }

        var result = settings
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    public static func status(of settings: [String: Any], link: URL, socket: URL) -> Status {
        guard let hooks = settings["hooks"] as? [String: Any] else { return .notInstalled }
        let expected = command(link: link, socket: socket)
        var found = 0
        var current = 0
        for event in ClaudeAdapter.hookEvents {
            let handlers = ((hooks[event] as? [Any]) ?? []).flatMap { ($0 as? [String: Any])?["hooks"] as? [Any] ?? [] }
            let ours = handlers.filter { isOurs($0, link: link) }
            found += ours.count
            if ours.count == 1, (ours[0] as? [String: Any])?["command"] as? String == expected { current += 1 }
        }
        if found == 0 { return .notInstalled }
        return current == ClaudeAdapter.hookEvents.count && found == current ? .installed : .outdated
    }

    /// Claude reads `$CLAUDE_CONFIG_DIR/settings.json`, falling back to `~/.claude`.
    public static func settingsFile(configDirectory: String?, home: URL) -> URL {
        if let configDirectory, !configDirectory.isEmpty {
            return URL(fileURLWithPath: configDirectory, isDirectory: true).appending(path: "settings.json")
        }
        return home.appending(path: ".claude", directoryHint: .isDirectory).appending(path: "settings.json")
    }

    // MARK: Files

    public static func install(file: URL, link: URL, socket: URL) throws {
        try update(file: file, createIfMissing: true, backup: true) {
            try installing(into: $0, link: link, socket: socket)
        }
    }

    public static func uninstall(file: URL, link: URL) throws {
        try update(file: file, createIfMissing: false, backup: false) {
            try removing(from: $0, link: link)
        }
    }

    public static func status(file: URL, link: URL, socket: URL) throws -> Status {
        guard let data = try read(file) else { return .notInstalled }
        return status(of: try parse(data, file: file), link: link, socket: socket)
    }

    private static func read(_ file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private static func parse(_ data: Data, file: URL) throws -> [String: Any] {
        // An empty file is what `touch settings.json` leaves behind; Claude treats it as no settings.
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.invalidJSON(file: file.lastPathComponent)
        }
        guard let dictionary = object as? [String: Any] else { throw Failure.notAnObject(file: file.lastPathComponent) }
        return dictionary
    }

    private static func update(
        file: URL,
        createIfMissing: Bool,
        backup: Bool,
        transform: ([String: Any]) throws -> [String: Any]
    ) throws {
        // Dotfile managers keep settings.json as a symlink; writing atomically to the link itself
        // would replace it with a regular file.
        let target = file.resolvingSymlinksInPath()
        let manager = FileManager.default

        // The file may be edited while we compute; if it changed under us, start again from the new text.
        for _ in 0..<3 {
            let original = try read(target)
            if original == nil, !createIfMissing { return }
            let settings = try original.map { try parse($0, file: target) } ?? [:]
            let updated = try transform(settings)
            if original != nil, NSDictionary(dictionary: updated).isEqual(to: settings) { return }

            let output = try JSONSerialization.data(
                withJSONObject: updated,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) + Data("\n".utf8)

            guard try read(target) == original else { continue }

            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
            if backup, original != nil {
                // Only once, so the backup is the user's original and not a file we already edited.
                let copy = target.deletingLastPathComponent().appending(path: target.lastPathComponent + ".archipel-backup")
                if !manager.fileExists(atPath: copy.path) { try? manager.copyItem(at: target, to: copy) }
            }
            try output.write(to: target, options: .atomic)
            if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
            return
        }
        throw Failure.changedWhileWriting(file: target.lastPathComponent)
    }
}
