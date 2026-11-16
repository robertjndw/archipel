import AppKit
import GitKit
import SwiftUI
import UISupport

/// Diff of one changed file in a git checkout, side by side or inline.
/// staged true: HEAD vs index. staged false: index vs working tree (an untracked file is all-added).
public struct DiffViewer: View {
    private let root: URL
    private let path: String
    private let staged: Bool
    private let review: DiffReview?

    public init(root: URL, path: String, staged: Bool) {
        self.root = root
        self.path = path
        self.staged = staged
        review = nil
    }

    /// A diff the user can comment on line by line. Comments go to `comments` under `root`, and the
    /// header lists every comment of the worktree with a control that calls `onSend` with the chosen
    /// target. Sending is the app's job: format with `ReviewPrompt`, deliver, then clear the store.
    public init(
        root: URL,
        path: String,
        staged: Bool,
        comments: ReviewCommentStore,
        targets: [ReviewTarget],
        onSend: @escaping (ReviewTarget.ID) -> Void
    ) {
        self.root = root
        self.path = path
        self.staged = staged
        review = DiffReview(store: comments, targets: targets, onSend: onSend)
    }

    public var body: some View {
        DiffViewerContent(root: root, path: path, staged: staged, review: review)
            .id(DiffKey(root: root, path: path, staged: staged))
    }

    private struct DiffKey: Hashable {
        var root: URL
        var path: String
        var staged: Bool
    }
}

private struct DiffViewerContent: View {
    @State private var model: DiffViewerModel
    @AppStorage("EditorUI.diffPresentation") private var presentation: DiffPresentation = .sideBySide
    @State private var showsAllLines = false
    let review: DiffReview?

    init(root: URL, path: String, staged: Bool, review: DiffReview?) {
        _model = State(initialValue: DiffViewerModel(root: root, path: path, staged: staged))
        self.review = review
    }

#if DEBUG
    init(model: DiffViewerModel, review: DiffReview?) {
        _model = State(initialValue: model)
        self.review = review
    }
#endif

    var body: some View {
        VStack(spacing: 0) {
            DiffHeader(model: model, review: review, presentation: $presentation, showsAllLines: $showsAllLines)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .refreshing(every: .seconds(3)) { await model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            Color.clear
        case .ready:
            if let document = model.document {
                DiffTextView(
                    document: document,
                    version: model.documentVersion,
                    presentation: presentation,
                    showsAllLines: showsAllLines,
                    highlights: model.highlights,
                    commenting: commenting,
                    path: model.path
                )
            }
        case .noDifferences:
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text(model.staged ? "Nothing staged for this file differs from the last commit." : "This file matches the staged version.")
            )
        case .binary:
            ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("Binary files can't be compared as text."))
        case .contentUnchanged:
            ContentUnavailableView("No Content Changes", systemImage: "doc.on.doc", description: Text("Only the file's name or permissions changed."))
        case .failed(let message):
            ContentUnavailableView("Can't Show Changes", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }

    private var commenting: DiffCommentContext? {
        guard let review else { return nil }
        let comments = review.store.comments(in: model.root).filter { $0.path == model.path && $0.staged == model.staged }
        return DiffCommentContext(store: review.store, root: model.root, path: model.path, staged: model.staged, comments: comments)
    }
}

private struct DiffHeader: View {
    let model: DiffViewerModel
    let review: DiffReview?
    @Binding var presentation: DiffPresentation
    @Binding var showsAllLines: Bool

    var body: some View {
        HStack(spacing: 8) {
            title
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(model.staged ? "Staged" : "Unstaged")
                .foregroundStyle(.secondary)
            if let document = model.document, model.phase == .ready {
                counts(document)
                lineEndings(document)
            }
            Spacer(minLength: 8)
            if let review {
                ReviewCommentsButton(root: model.root, review: review)
            }
            if model.phase == .ready {
                Toggle(isOn: $showsAllLines) {
                    Label(showsAllLines ? "Collapse Unchanged Lines" : "Show Unchanged Lines",
                          systemImage: showsAllLines ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help(showsAllLines ? "Collapse Unchanged Lines" : "Show Unchanged Lines")

                Picker("Presentation", selection: $presentation) {
                    Label("Side by Side", systemImage: "rectangle.split.2x1").tag(DiffPresentation.sideBySide)
                    Label("Inline", systemImage: "rectangle.split.1x2").tag(DiffPresentation.inline)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Choose how changes are presented")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    @ViewBuilder
    private var title: some View {
        let name = (model.path as NSString).lastPathComponent
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let original = model.renamedFrom {
                Text(verbatim: original)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .accessibilityLabel("renamed to")
                Text(verbatim: model.path)
            } else {
                Text(verbatim: name)
                let folder = (model.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(verbatim: folder)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help(model.path)
    }

    private func counts(_ document: DiffDocument) -> some View {
        HStack(spacing: 6) {
            if document.additions > 0 {
                Text(verbatim: "+\(document.additions)")
                    .foregroundStyle(.green)
            }
            if document.deletions > 0 {
                Text(verbatim: "-\(document.deletions)")
                    .foregroundStyle(.red)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(document.additions) lines added, \(document.deletions) lines removed")
    }

    @ViewBuilder
    private func lineEndings(_ document: DiffDocument) -> some View {
        if let old = document.old.lineEnding, let new = document.new.lineEnding, old != new {
            HStack(spacing: 3) {
                Text(verbatim: old.label)
                Image(systemName: "arrow.right")
                    .imageScale(.small)
                Text(verbatim: new.label)
            }
            .foregroundStyle(.orange)
            .help("Line endings changed")
        }
    }
}

@MainActor @Observable
final class DiffViewerModel {
    enum Phase: Equatable {
        case loading, ready, noDifferences, binary, contentUnchanged
        case failed(String)

        /// Whether `diff` describes what is on screen, so identical output can be skipped.
        var isSettled: Bool {
            switch self {
            case .loading, .failed: false
            default: true
            }
        }
    }

    let root: URL
    let path: String
    let staged: Bool
    private(set) var phase = Phase.loading
    private(set) var document: DiffDocument?
    private(set) var documentVersion = 0
    private(set) var highlights: DiffHighlights?
    private(set) var renamedFrom: String?
    @ObservationIgnored private var diff: GitFileDiff?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    private let loadDiff: @Sendable (_ path: String, _ staged: Bool, _ root: URL) async throws -> GitFileDiff?

    /// `loadDiff` is only replaced by previews, which have no repository to run git in.
    init(
        root: URL,
        path: String,
        staged: Bool,
        loadDiff: @escaping @Sendable (_ path: String, _ staged: Bool, _ root: URL) async throws -> GitFileDiff? = { path, staged, root in
            try await GitClient().fileDiff(path: path, staged: staged, in: root)
        }
    ) {
        self.root = root
        self.path = path
        self.staged = staged
        self.loadDiff = loadDiff
    }

    func refresh() async {
        // The poll, app activation and the first appearance can overlap; only the newest may write.
        generation += 1
        let current = generation
        do {
            let diff = try await loadDiff(path, staged, root)
            guard current == generation else { return }
            // Unchanged output leaves the view alone, so scroll position and expanded folds survive the poll.
            if phase.isSettled, diff == self.diff { return }
            self.diff = diff
            renamedFrom = diff?.status == .renamed && diff?.oldPath != path ? diff?.oldPath : nil

            guard let diff else { return show(.noDifferences) }
            if diff.isBinary { return show(.binary) }
            if diff.hunks.isEmpty { return show(.contentUnchanged) }

            let document = await Self.makeDocument(diff)
            guard current == generation else { return }
            self.document = document
            documentVersion += 1
            phase = .ready
            highlight(document, version: documentVersion)
        } catch {
            guard current == generation else { return }
            self.diff = nil
            show(.failed(error.localizedDescription))
        }
    }

    private func show(_ phase: Phase) {
        highlightTask?.cancel()
        document = nil
        highlights = nil
        self.phase = phase
    }

    private func highlight(_ document: DiffDocument, version: Int) {
        highlightTask?.cancel()
        guard let grammar = SourceLanguage.grammar(forFileName: (path as NSString).lastPathComponent) else { return }
        highlightTask = Task { [weak self] in
            async let old = SyntaxHighlighter.shared.runs(for: document.old.text, grammar: grammar)
            async let new = SyntaxHighlighter.shared.runs(for: document.new.text, grammar: grammar)
            let (oldRuns, newRuns) = await (old, new)
            guard let self, !Task.isCancelled, self.documentVersion == version else { return }
            self.highlights = DiffHighlights(documentVersion: version, old: oldRuns ?? [], new: newRuns ?? [])
        }
    }

    @concurrent
    private nonisolated static func makeDocument(_ diff: GitFileDiff) async -> DiffDocument {
        DiffDocument(diff: diff)
    }
}

#if DEBUG
@MainActor
private func previewViewer(
    _ result: Result<GitFileDiff?, GitError>,
    path: String,
    staged: Bool = false,
    review: DiffReview? = nil
) -> some View {
    let model = DiffViewerModel(root: PreviewSamples.root, path: path, staged: staged) { _, _, _ in try result.get() }
    return DiffViewerContent(model: model, review: review)
        .frame(width: 900, height: 520)
}

#Preview("Modified") {
    previewViewer(.success(PreviewSamples.mixed), path: PreviewSamples.mixedPath)
}

#Preview("Review Comments") {
    previewViewer(.success(PreviewSamples.mixed), path: PreviewSamples.mixedPath, review: PreviewSamples.review(comments: 4, targets: 2))
}

#Preview("Review Comments, Dark") {
    previewViewer(.success(PreviewSamples.mixed), path: PreviewSamples.mixedPath, review: PreviewSamples.review(comments: 4, targets: 2))
        .preferredColorScheme(.dark)
}

#Preview("Staged New File") {
    previewViewer(.success(PreviewSamples.newFile), path: "Sources/Sessions/SessionBadge.swift", staged: true)
}

#Preview("Renamed") {
    previewViewer(.success(PreviewSamples.renamed), path: "Sources/Util/StringHelpers.swift")
}

#Preview("Line Endings Changed") {
    previewViewer(.success(PreviewSamples.lineEndings), path: ".editorconfig")
}

#Preview("Binary") {
    previewViewer(.success(PreviewSamples.binary), path: "Assets/AppIcon.png")
}

#Preview("Renamed Without Changes") {
    previewViewer(.success(PreviewSamples.renamedOnly), path: "Sources/Util/StringHelpers.swift", staged: true)
}

#Preview("No Changes") {
    previewViewer(.success(nil), path: PreviewSamples.mixedPath, staged: true)
}

#Preview("Failed") {
    previewViewer(.failure(GitError(message: "fatal: not a git repository (or any of the parent directories): .git")), path: PreviewSamples.mixedPath)
}
#endif
