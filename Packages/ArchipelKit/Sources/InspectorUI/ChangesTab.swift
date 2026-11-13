import GitKit
import SwiftUI

struct ChangeID: Hashable {
    var path: String
    var staged: Bool
}

@MainActor @Observable
final class ChangesModel {
    enum Phase { case loading, notRepository, ready }

    let root: URL
    private(set) var status = GitStatus.empty
    private(set) var phase = Phase.loading
    private(set) var refreshError: String?
    var actionError: String?
    var selection: ChangeID?
    private let git = GitClient()
    private var generation = 0

    init(root: URL) {
        self.root = root
    }

    func refresh() async {
        // Periodic, activation and post-action refreshes can overlap; only the newest may write.
        generation += 1
        let current = generation
        do {
            let status = try await git.status(in: root)
            guard current == generation else { return }
            self.status = status
            phase = .ready
            refreshError = nil
        } catch {
            let isRepository = await git.isRepository(root)
            guard current == generation else { return }
            if isRepository {
                refreshError = error.localizedDescription
            } else {
                status = .empty
                phase = .notRepository
                refreshError = nil
            }
        }
    }

    func stage(_ change: GitFileChange) {
        perform { try await $0.stage([change.path], in: $1) }
    }

    func unstage(_ change: GitFileChange) {
        // Unstaging only the new name of a rename would leave the old name's deletion staged.
        let paths = [change.path] + [change.originalPath].compactMap(\.self)
        perform { try await $0.unstage(paths, in: $1) }
    }

    func stageAll() {
        perform { try await $0.stageAll(in: $1) }
    }

    func unstageAll() {
        perform { try await $0.unstageAll(in: $1) }
    }

    func change(for id: ChangeID) -> GitFileChange? {
        (id.staged ? status.staged : status.unstaged).first { $0.path == id.path }
    }

    func url(for change: GitFileChange) -> URL {
        root.appending(path: change.path)
    }

    private func perform(_ action: @escaping @Sendable (GitClient, URL) async throws -> Void) {
        let git = git
        let root = root
        Task {
            do {
                try await action(git, root)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
            await refresh()
        }
    }
}

struct ChangesTab: View {
    @Bindable var model: ChangesModel
    let actions: InspectorActions
    @State private var showsStaged = true
    @State private var showsUnstaged = true

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(refresh: refresh) {
                if let branch = model.status.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                } else if model.phase == .ready {
                    Label("Detached HEAD", systemImage: "arrow.triangle.branch")
                }
            }

            if let message = model.actionError ?? model.refreshError {
                ErrorBanner(message: message, dismiss: model.actionError == nil ? nil : { model.actionError = nil })
            }

            content
                .frame(maxHeight: .infinity)
        }
        .task {
            // Lives only while this tab is on screen, so the polling stops when the user switches away.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onAppActivation(perform: refresh)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .notRepository:
            ContentUnavailableView(
                "Not a Git Repository",
                systemImage: "arrow.triangle.branch",
                description: Text("This folder isn't tracked by Git.")
            )
        case .ready where model.status.staged.isEmpty && model.status.unstaged.isEmpty:
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("The working tree is clean.")
            )
        case .ready:
            List(selection: $model.selection) {
                if !model.status.staged.isEmpty {
                    section("Staged Changes", changes: model.status.staged, staged: true, isExpanded: $showsStaged)
                }
                if !model.status.unstaged.isEmpty {
                    section("Changes", changes: model.status.unstaged, staged: false, isExpanded: $showsUnstaged)
                }
            }
            .listStyle(.sidebar)
            .compactRows()
            .contextMenu(forSelectionType: ChangeID.self) { ids in
                if let id = ids.first, let change = model.change(for: id) {
                    ChangeContextMenu(change: change, staged: id.staged, model: model, actions: actions)
                }
            } primaryAction: { ids in
                for id in ids { actions.openDiff(id.path, id.staged, false) }
            }
            .onChange(of: model.selection) { _, selection in
                if let selection { actions.openDiff(selection.path, selection.staged, true) }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, changes: [GitFileChange], staged: Bool, isExpanded: Binding<Bool>) -> some View {
        Section(isExpanded: isExpanded) {
            ForEach(changes) { change in
                ChangeRow(change: change, staged: staged, model: model)
                    .tag(ChangeID(path: change.path, staged: staged))
            }
        } header: {
            HStack {
                Text(title)
                Text(changes.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button(staged ? "Unstage All" : "Stage All", systemImage: staged ? "minus" : "plus") {
                    staged ? model.unstageAll() : model.stageAll()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(staged ? "Unstage All Changes" : "Stage All Changes")
            }
        }
    }

    private func refresh() {
        Task { await model.refresh() }
    }
}

private struct ChangeRow: View {
    let change: GitFileChange
    let staged: Bool
    let model: ChangesModel
    @State private var isHovering = false

    var body: some View {
        let name = (change.path as NSString).lastPathComponent
        let directory = (change.path as NSString).deletingLastPathComponent

        HStack(spacing: 6) {
            Image(systemName: FileIcon.symbol(for: name))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(name)
                .strikethrough(change.kind == .deleted)
                .lineLimit(1)
                .layoutPriority(1)
            Text(directory)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if isHovering {
                Button(staged ? "Unstage Changes" : "Stage Changes", systemImage: staged ? "minus" : "plus", action: toggleStage)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(staged ? "Unstage Changes" : "Stage Changes")
            }
            Text(change.kind.letter)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(change.kind.color)
                .frame(minWidth: 14)
                .accessibilityLabel(change.kind.description)
        }
        .onHover { isHovering = $0 }
        .help(change.originalPath.map { "\(change.path), renamed from \($0)" } ?? change.path)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: staged ? "Unstage" : "Stage", toggleStage)
    }

    private func toggleStage() {
        staged ? model.unstage(change) : model.stage(change)
    }
}

private struct ChangeContextMenu: View {
    let change: GitFileChange
    let staged: Bool
    let model: ChangesModel
    let actions: InspectorActions

    var body: some View {
        Button(staged ? "Unstage Changes" : "Stage Changes") {
            staged ? model.unstage(change) : model.stage(change)
        }
        Divider()
        Button("Open File") { actions.openFile(model.url(for: change), false) }
            .disabled(change.kind == .deleted)
        Button("Open in Default App") { FileActions.open([model.url(for: change)]) }
            .disabled(change.kind == .deleted)
        Button("Reveal in Finder") { FileActions.reveal([model.url(for: change)]) }
            .disabled(change.kind == .deleted)
        Button("Copy Relative Path") { FileActions.copy([change.path]) }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(8)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

extension GitChangeKind {
    var letter: String {
        switch self {
        case .modified, .typeChanged: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    var color: Color {
        switch self {
        case .modified, .typeChanged: .orange
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        case .renamed, .copied: .blue
        }
    }

    var description: LocalizedStringKey {
        switch self {
        case .modified: "Modified"
        case .typeChanged: "Type Changed"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }
}
