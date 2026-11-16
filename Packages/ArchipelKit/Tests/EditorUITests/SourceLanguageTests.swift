import Foundation
import Testing
@testable import EditorUI

struct SourceLanguageTests {
    @Test(arguments: [
        ("main.swift", "swift"), ("Package.swift", "swift"), ("lib.rs", "rust"), ("App.tsx", "typescript"),
        ("index.mjs", "javascript"), ("tool.py", "python"), ("main.go", "go"), ("x.c", "c"), ("x.hpp", "cpp"),
        ("data.json", "json"), ("ci.yml", "yaml"), ("Cargo.toml", "ini"), ("README.md", "markdown"),
        ("build.sh", "bash"), ("index.html", "xml"), ("site.css", "css"), ("schema.sql", "sql"),
        ("Dockerfile", "dockerfile"), ("Dockerfile.dev", "dockerfile"), ("Makefile", "makefile"),
        (".gitignore", "bash"), (".env.local", "bash"), ("CMakeLists.txt", "cmake"), ("Gemfile", "ruby"),
    ])
    func detectsGrammar(_ name: String, _ grammar: String) {
        #expect(SourceLanguage.grammar(forFileName: name) == grammar)
    }

    @Test func unknownFilesHaveNoGrammar() {
        #expect(SourceLanguage.grammar(forFileName: "LICENSE") == nil)
        #expect(SourceLanguage.grammar(forFileName: "photo.heic") == nil)
    }
}
