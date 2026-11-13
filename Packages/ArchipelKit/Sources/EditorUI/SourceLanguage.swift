import Foundation

/// Maps a file name to the highlight.js grammar that should colour it.
enum SourceLanguage {
    static func grammar(forFileName fileName: String) -> String? {
        let name = fileName.lowercased()
        if let grammar = wellKnownNames[name] { return grammar }
        if name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") { return "dockerfile" }
        if name.hasPrefix(".env.") { return "bash" }
        if name.hasPrefix("makefile.") { return "makefile" }

        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return extensions[ext]
    }

    private static let wellKnownNames: [String: String] = [
        "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "makefile": "makefile", "gnumakefile": "makefile", "justfile": "makefile",
        "cmakelists.txt": "cmake",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "fastfile": "ruby", "appfile": "ruby",
        "brewfile": "ruby", "vagrantfile": "ruby", "dangerfile": "ruby", "guardfile": "ruby",
        ".gitignore": "bash", ".dockerignore": "bash", ".gitattributes": "bash", ".npmignore": "bash",
        ".gitconfig": "ini", ".gitmodules": "ini", ".editorconfig": "ini", ".npmrc": "ini",
        ".env": "bash", ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "bash", ".zprofile": "bash",
        ".zshenv": "bash", ".profile": "bash", ".swiftformat": "bash",
        ".swiftlint.yml": "yaml", ".clang-format": "yaml",
        ".prettierrc": "json", ".eslintrc": "json", ".babelrc": "json",
        "package.resolved": "json", "cargo.lock": "ini", "poetry.lock": "ini", "uv.lock": "ini",
        "go.mod": "go",
        "nginx.conf": "nginx",
    ]

    private static let extensions: [String: String] = [
        "swift": "swift", "swiftinterface": "swift",
        "rs": "rust",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "py": "python", "pyi": "python", "pyw": "python",
        "go": "go",
        "c": "c", "h": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "c++": "cpp", "hh": "cpp", "hpp": "cpp", "hxx": "cpp", "ipp": "cpp",
        "m": "objectivec", "mm": "objectivec",
        "json": "json", "jsonc": "json", "json5": "json", "jsonl": "json", "geojson": "json", "webmanifest": "json",
        "yml": "yaml", "yaml": "yaml",
        "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini", "xcconfig": "ini",
        "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "command": "bash", "ksh": "bash",
        "html": "xml", "htm": "xml", "xhtml": "xml", "xml": "xml", "svg": "xml", "plist": "xml",
        "xib": "xml", "storyboard": "xml", "entitlements": "xml", "xcscheme": "xml", "vue": "xml", "svelte": "xml",
        "css": "css", "scss": "scss", "less": "less",
        "sql": "sql",
        "dockerfile": "dockerfile",
        "mk": "makefile", "mak": "makefile",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala", "groovy": "groovy", "gradle": "gradle",
        "rb": "ruby", "php": "php", "lua": "lua", "pl": "perl", "pm": "perl", "r": "r",
        "cs": "csharp", "fs": "fsharp", "dart": "dart", "ex": "elixir", "exs": "elixir", "erl": "erlang",
        "hs": "haskell", "ml": "ocaml", "mli": "ocaml", "clj": "clojure", "cljs": "clojure", "jl": "julia",
        "nim": "nim", "nix": "nix", "vim": "vim", "tex": "latex", "cmake": "cmake",
        "proto": "protobuf", "graphql": "graphql", "gql": "graphql", "properties": "properties",
        "ps1": "powershell", "psm1": "powershell", "bat": "dos", "cmd": "dos",
        "diff": "diff", "patch": "diff", "glsl": "glsl", "metal": "cpp",
        "http": "http", "applescript": "applescript",
    ]
}
