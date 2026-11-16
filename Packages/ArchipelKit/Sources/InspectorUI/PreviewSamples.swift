#if DEBUG
import GitKit
import SwiftUI

/// Sample data for the InspectorUI previews. Every path points into a folder that does not exist, and
/// the models made from it never run git or read the disk.
@MainActor
enum PreviewSamples {
    nonisolated static let root = URL(filePath: "/tmp/archipel-preview/archipel", directoryHint: .isDirectory)

    static let actions = InspectorActions(openFile: { _, _ in }, openDiff: { _, _, _ in }, switchBranch: {})

    // MARK: Status

    static let clean = GitStatus(branch: "main", staged: [], unstaged: [], upstream: "origin/main")

    /// Every kind of row: a partially staged file in both sections, a rename, a deletion, a conflict
    /// and an untracked file.
    static let mixed = GitStatus(
        branch: "feat/inspector-previews",
        staged: [
            GitFileChange(path: "Sources/App/AppModel.swift", kind: .modified),
            GitFileChange(path: "Sources/App/PreviewFixtures.swift", kind: .added),
            GitFileChange(path: "Docs/Guide.md", originalPath: "README-old.md", kind: .renamed),
        ],
        unstaged: [
            GitFileChange(path: "Sources/App/AppModel.swift", kind: .modified),
            GitFileChange(path: "Tests/LegacyTests.swift", kind: .deleted),
            GitFileChange(path: "Package.resolved", kind: .conflicted),
            GitFileChange(path: "notes/todo.md", kind: .untracked),
        ],
        upstream: "origin/feat/inspector-previews",
        ahead: 2,
        behind: 1
    )

    static let stagedOnly = GitStatus(
        branch: "main",
        staged: [GitFileChange(path: "Sources/App/AppModel.swift", kind: .modified)],
        unstaged: [],
        upstream: "origin/main"
    )

    static let unstagedOnly = GitStatus(
        branch: "main",
        staged: [],
        unstaged: [
            GitFileChange(path: "Sources/App/AppModel.swift", kind: .modified),
            GitFileChange(path: "notes/todo.md", kind: .untracked),
        ],
        upstream: "origin/main"
    )

    static func synced(ahead: Int = 0, behind: Int = 0, upstream: String? = "origin/main", branch: String? = "main") -> GitStatus {
        GitStatus(branch: branch, staged: [], unstaged: [], upstream: upstream, ahead: ahead, behind: behind)
    }

    static func pullRequest(_ state: GitPullRequest.State, isDraft: Bool = false) -> GitPullRequest {
        GitPullRequest(
            number: 42,
            url: URL(string: "https://example.invalid/pull/42")!,
            title: "Add previews to the inspector",
            state: state,
            isDraft: isDraft
        )
    }

    // MARK: Files

    private nonisolated static let tree: [String: [(String, Bool)]] = [
        "": [("Docs", true), ("Sources", true), ("Tests", true), (".gitignore", false), ("Package.swift", false), ("README.md", false)],
        "Sources": [("App", true), ("Resources", true)],
        "Sources/App": [("AppModel.swift", false), ("ContentView.swift", false), ("Settings.json", false)],
        "Sources/Resources": [("AppIcon.png", false), ("Localizable.xcstrings", false)],
        "Docs": [("Guide.md", false)],
        "Tests": [("AppModelTests.swift", false)],
    ]

    /// Lists the sample tree instead of the disk.
    static let listDirectory: @Sendable (URL) async throws -> [FileNode] = { directory in
        let relative = directory.path(percentEncoded: false)
            .replacingOccurrences(of: root.path(percentEncoded: false), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (tree[relative] ?? []).map { name, isDirectory in
            FileNode(url: directory.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory), name: name, isDirectory: isDirectory)
        }
    }

    static func fileTree(expanding folders: [String] = []) -> FileTreeModel {
        let model = FileTreeModel(root: root, listDirectory: listDirectory)
        for folder in folders {
            model.setExpanded(root.appending(path: folder, directoryHint: .isDirectory), true)
        }
        return model
    }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            content
        }
    }
}
#endif
