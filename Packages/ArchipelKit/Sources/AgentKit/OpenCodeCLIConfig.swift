import Foundation

/// OpenCode's own CLI config (`cli.json`), of which Archipel only needs the TUI plugin list.
public enum OpenCodeCLIConfig {
    /// `$XDG_CONFIG_HOME/opencode/cli.json`, else `~/.config/opencode/cli.json`.
    public static func fileURL(environment: [String: String], homeDirectory: URL) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
        return base.appending(path: "opencode/cli.json")
    }

    /// The user's plugins, each as a JSON fragment. Empty when there is no config file. Nil when
    /// there is one but its plugins cannot be made out: OpenCode replaces the list with whatever
    /// we pass, so guessing would drop the user's plugins.
    public static func userPlugins(environment: [String: String], homeDirectory: URL) -> [String]? {
        let url = fileURL(environment: environment, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return userPlugins(in: data)
    }

    public static func userPlugins(in data: Data) -> [String]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let json = Data(stripTrailingCommas(stripComments(text)).utf8)
        guard json.contains(where: { !" \n\r\t".utf8.contains($0) }) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        guard let plugins = object["plugins"] else { return [] }
        guard let list = plugins as? [Any] else { return nil }
        var fragments: [String] = []
        for plugin in list {
            guard let data = try? JSONSerialization.data(withJSONObject: plugin, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                  let fragment = String(data: data, encoding: .utf8)
            else { return nil }
            fragments.append(fragment)
        }
        return fragments
    }

    /// The value for `OPENCODE_CLI_CONFIG_CONTENT`: the user's plugins first, ours last.
    public static func injectedConfig(userPlugins: [String], pluginDirectory: URL) -> String {
        let ours = (try? JSONSerialization.data(withJSONObject: pluginDirectory.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return #"{"plugins":["# + (userPlugins + [ours]).joined(separator: ",") + "]}"
    }

    /// `cli.json` may be JSONC. Quoted strings are skipped so a `//` inside a URL survives.
    static func stripComments(_ text: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                result.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                index = next
            } else if character == "\"" {
                inString = true
                result.append(character)
                index = next
            } else if character == "/", next < text.endIndex, text[next] == "/" {
                index = text[next...].firstIndex(of: "\n") ?? text.endIndex
            } else if character == "/", next < text.endIndex, text[next] == "*" {
                guard let end = text.range(of: "*/", range: text.index(after: next)..<text.endIndex) else { return result }
                index = end.upperBound
                result.append(" ")
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }

    static func stripTrailingCommas(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var inString = false
        var escaped = false
        for (offset, character) in characters.enumerated() {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "," {
                let following = characters[(offset + 1)...].first { !$0.isWhitespace }
                if following == "}" || following == "]" { continue }
            }
            result.append(character)
        }
        return result
    }
}
