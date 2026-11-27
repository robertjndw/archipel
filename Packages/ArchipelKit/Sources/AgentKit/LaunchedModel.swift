import Foundation

/// The model a launch picks by its arguments, so a tab can name it before the agent reports one.
public enum LaunchedModel {
    /// The value of the last `--model X`, `--model=X`, `-m X` or `-c model=X` (Codex), as typed.
    /// The last one wins because that is the one the agent ends up using.
    public static func name(in arguments: [String]) -> String? {
        var found: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            index += 1
            if argument == "--model" || argument == "-m" {
                if let next { found = next; index += 1 }
            } else if argument.hasPrefix("--model=") {
                found = String(argument.dropFirst("--model=".count))
            } else if argument == "-c" || argument == "--config" {
                if let next, next.hasPrefix("model=") {
                    found = String(next.dropFirst("model=".count))
                    index += 1
                }
            }
        }
        // Codex's config values are TOML, so a string may arrive quoted.
        guard let value = found?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), !value.isEmpty else { return nil }
        return value
    }
}
