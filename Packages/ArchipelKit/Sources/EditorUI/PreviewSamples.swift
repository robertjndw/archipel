#if DEBUG
import GitKit
import SwiftUI

/// Sample data for the EditorUI previews. Every path points into a folder that does not exist, and
/// nothing here runs git or reads a file.
@MainActor
enum PreviewSamples {
    static let root = URL(filePath: "/tmp/archipel-preview/repo", directoryHint: .isDirectory)

    static func url(_ path: String) -> URL {
        root.appending(path: path)
    }

    // MARK: Diffs

    /// Builds a whole-file hunk from lines written the way `git diff` prints them: a leading space,
    /// `+` or `-`, then the text.
    static func diff(
        _ path: String,
        status: GitFileDiff.Status = .modified,
        from oldPath: String? = nil,
        missingNewlineAtEnd: Bool = false,
        _ text: String
    ) -> GitFileDiff {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> GitDiffLine in
            let kind: GitDiffLine.Kind = switch raw.first {
            case "+": .added
            case "-": .removed
            default: .context
            }
            return GitDiffLine(kind, String(raw.dropFirst()))
        }
        if missingNewlineAtEnd, !lines.isEmpty {
            lines[lines.count - 1].hasNewline = false
        }
        let oldCount = lines.count { $0.kind != .added }
        let newCount = lines.count { $0.kind != .removed }
        let hunk = GitDiffHunk(
            oldStart: oldCount == 0 ? 0 : 1, oldCount: oldCount,
            newStart: newCount == 0 ? 0 : 1, newCount: newCount,
            lines: lines
        )
        return GitFileDiff(
            oldPath: status == .added ? nil : oldPath ?? path,
            newPath: status == .deleted ? nil : path,
            status: status,
            hunks: [hunk]
        )
    }

    static let mixedPath = "Sources/Sessions/RecentSessions.swift"

    /// Two changes far enough apart that the unchanged run between them folds.
    static let mixed = diff(mixedPath, """
         import Foundation

         /// Keeps the most recent sessions so the switcher can offer them first.
         struct RecentSessions {
        -    private var items: [String] = []
        +    private var items: [Session.ID] = []
             let limit: Int

             init(limit: Int = 8) {
                 self.limit = limit
             }

             var first: Session.ID? {
                 items.first
             }

             var count: Int {
                 items.count
             }

             func contains(_ id: Session.ID) -> Bool {
                 items.contains(id)
             }

        -    mutating func touch(_ id: String) {
        +    mutating func touch(_ id: Session.ID) {
                 items.removeAll { $0 == id }
                 items.insert(id, at: 0)
        -        if items.count > limit { items.removeLast() }
        +        if items.count > limit {
        +            items.removeLast(items.count - limit)
        +        }
             }
        +
        +    mutating func forget(_ id: Session.ID) {
        +        items.removeAll { $0 == id }
        +    }
         }
        """)

    static let additionsOnly = diff("Sources/Sessions/SessionFormatter.swift", """
         struct SessionFormatter {
             func title(for session: Session) -> String {
        +        if let custom = session.customTitle, !custom.isEmpty {
        +            return custom
        +        }
                 return session.agent.displayName
             }
         }
        +
        +extension SessionFormatter {
        +    static let shared = SessionFormatter()
        +}
        """)

    static let deletionsOnly = diff("Sources/Sessions/LegacyMigration.swift", """
         enum LegacyMigration {
        -    /// Version 1 stored sessions by window number.
        -    static func migrateWindowNumbers(_ defaults: UserDefaults) {
        -        defaults.removeObject(forKey: "sessionsByWindow")
        -    }
        -
             static func run(_ defaults: UserDefaults) {
        -        migrateWindowNumbers(defaults)
                 defaults.set(2, forKey: "schemaVersion")
             }
         }
        """)

    static let newFile = diff("Sources/Sessions/SessionBadge.swift", status: .added, """
        +import SwiftUI
        +
        +struct SessionBadge: View {
        +    let count: Int
        +
        +    var body: some View {
        +        Text(count, format: .number)
        +            .font(.caption.monospacedDigit())
        +            .padding(.horizontal, 6)
        +            .background(.tint, in: .capsule)
        +    }
        +}
        """)

    static let renamed = diff("Sources/Util/StringHelpers.swift", status: .renamed, from: "Sources/Helpers.swift", """
         extension String {
        -    var trimmed: String { trimmingCharacters(in: .whitespaces) }
        +    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
         }
        """)

    static let renamedOnly = GitFileDiff(oldPath: "Sources/Helpers.swift", newPath: "Sources/Util/StringHelpers.swift", status: .renamed)

    static let conflicted = GitFileDiff(oldPath: mixedPath, newPath: mixedPath, status: .modified, isConflicted: true)

    static let binary = GitFileDiff(oldPath: "Assets/AppIcon.png", newPath: "Assets/AppIcon.png", status: .modified, isBinary: true)

    /// Same text on both sides, only the line endings differ, so the header shows LF to CRLF.
    static let lineEndings: GitFileDiff = {
        let lines = ["[*]", "indent_style = space", "indent_size = 4"]
        let hunk = GitDiffHunk(
            oldStart: 1, oldCount: lines.count, newStart: 1, newCount: lines.count,
            lines: lines.map { GitDiffLine(.removed, $0) } + lines.map { GitDiffLine(.added, $0 + "\r") }
        )
        return GitFileDiff(oldPath: ".editorconfig", newPath: ".editorconfig", status: .modified, hunks: [hunk])
    }()

    /// A line past the renderer's drawing limit, which ends in an ellipsis, and one that only scrolls.
    static let longLines: GitFileDiff = {
        let bundle = (0..<400).map { "a\($0)=function(){return \($0)}" }.joined(separator: ";")
        return diff("web/dist/app.min.js", """
         // build 41
        -var config={"api":"https://api.example.invalid/v1","timeout":3000,"retries":2,"features":["sessions","review","inspector"]};
        +var config={"api":"https://api.example.invalid/v2","timeout":5000,"retries":3,"features":["sessions","review","inspector","diff"]};
        -\(bundle)
        +\(bundle);a400=function(){return 400}
        """)
    }()

    static let missingNewline = diff("Package.swift", missingNewlineAtEnd: true, """
         // swift-tools-version: 6.2
         import PackageDescription

        -let package = Package(name: "Archipel")
        +let package = Package(name: "Archipel", platforms: [.macOS("27.0")])
        """)

    static let plainText = diff("NOTES", """
         Things to check before the release:
        -- the installer
        +- the installer, on a clean machine
         - the update feed
        +- the crash reporter
        """)

    // MARK: Review comments

    static let targets = [
        ReviewTarget(id: UUID(), title: "Claude Code", symbolName: "sparkle"),
        ReviewTarget(id: UUID(), title: "Codex", symbolName: "terminal"),
    ]

    static func comments(_ count: Int) -> ReviewCommentStore {
        let store = ReviewCommentStore()
        let all = [
            ReviewComment(path: mixedPath, staged: false, side: .new, line: 5, lineText: "    private var items: [Session.ID] = []",
                          body: "Will sessions saved by the old build still decode after this change?"),
            ReviewComment(path: mixedPath, staged: false, side: .old, line: 27, lineText: "        if items.count > limit { items.removeLast() }",
                          body: "This only ever removed one item, so a smaller limit left the list too long."),
            ReviewComment(path: mixedPath, staged: false, side: .new, line: 32, lineText: "    mutating func forget(_ id: Session.ID) {",
                          body: "Call this when a session closes, otherwise the switcher keeps offering it."),
            ReviewComment(path: "Sources/Sessions/SessionFormatter.swift", staged: true, side: .new, line: 3,
                          lineText: "        if let custom = session.customTitle, !custom.isEmpty {",
                          body: "Trim whitespace first, a title of only spaces should fall back too."),
        ]
        for comment in all.prefix(count) { store.add(comment, in: root) }
        return store
    }

    static func review(comments: Int, targets: Int = 1) -> DiffReview {
        DiffReview(store: Self.comments(comments), targets: Array(Self.targets.prefix(targets)), onSend: { _ in })
    }

    static func commenting(_ store: ReviewCommentStore, path: String = mixedPath, staged: Bool = false) -> DiffCommentContext {
        let comments = store.comments(in: root).filter { $0.path == path && $0.staged == staged }
        return DiffCommentContext(store: store, root: root, path: path, staged: staged, comments: comments)
    }

    // MARK: Files

    static let swiftSource = """
        import SwiftUI

        /// Shows how many agents are working in a worktree.
        struct ActivityBadge: View {
            let running: Int
            var isPaused = false

            var body: some View {
                // Hidden rather than removed, so the row keeps its height.
                Text("\\(running) running")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isPaused ? .secondary : .primary)
                    .opacity(running > 0 ? 1 : 0)
            }
        }

        #Preview {
            ActivityBadge(running: 3)
        }

        """

    static let jsonSource = """
        {
          "name": "archipel-preview",
          "version": "1.4.0",
          "private": true,
          "scripts": {
            "dev": "vite --port 5173",
            "test": "vitest run"
          },
          "dependencies": {
            "react": "^19.1.0"
          },
          "workspaces": ["packages/*"],
          "retries": 3,
          "telemetry": null
        }

        """

    static let markdownSource = """
        # Archipel

        Run several coding agents side by side, **one worktree each**.

        ## Getting started

        1. Open a repository with `File > Open`.
        2. Press `Command-T` for a new session.
        3. Review the changes in the inspector.

        > Sessions keep running when you switch islands.

        See [the docs](https://example.invalid/docs) for more.

        """

    static let plainSource = """
        Release checklist

        - bump the build number
        - run the installer on a clean machine
        - check the update feed
        - write the release notes

        """
}

/// A caption above a variant, for previews that stack several states of one component.
struct PreviewVariant<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// A diff as DiffViewer would show it once loaded, highlighted like the real thing.
struct DiffPreview: View {
    let path: String
    let document: DiffDocument
    var presentation = DiffPresentation.sideBySide
    var showsAllLines = false
    var commenting: DiffCommentContext?
    @State private var highlights: DiffHighlights?

    init(_ diff: GitFileDiff, presentation: DiffPresentation = .sideBySide, showsAllLines: Bool = false, commenting: DiffCommentContext? = nil) {
        path = diff.newPath ?? diff.oldPath ?? ""
        document = DiffDocument(diff: diff)
        self.presentation = presentation
        self.showsAllLines = showsAllLines
        self.commenting = commenting
    }

    var body: some View {
        DiffTextView(
            document: document,
            version: 1,
            presentation: presentation,
            showsAllLines: showsAllLines,
            highlights: highlights,
            commenting: commenting,
            path: path
        )
        .task {
            guard let grammar = SourceLanguage.grammar(forFileName: (path as NSString).lastPathComponent) else { return }
            async let old = SyntaxHighlighter.shared.runs(for: document.old.text, grammar: grammar)
            async let new = SyntaxHighlighter.shared.runs(for: document.new.text, grammar: grammar)
            let (oldRuns, newRuns) = await (old, new)
            highlights = DiffHighlights(documentVersion: 1, old: oldRuns ?? [], new: newRuns ?? [])
        }
    }
}
#endif
