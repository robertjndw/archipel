import AppKit
import GitKit
import SwiftUI

/// What the primary button says and whether it can be pressed.
struct CommitControl: Equatable {
    enum Mode: Equatable { case commit, commitAll }

    var mode: Mode
    var hasChanges: Bool
    var isEnabled: Bool

    init(status: GitStatus, message: String, isBusy: Bool) {
        hasChanges = !status.staged.isEmpty || !status.unstaged.isEmpty
        // With nothing staged, "Commit All" is the only thing a commit can mean.
        mode = status.staged.isEmpty && hasChanges ? .commitAll : .commit
        let hasMessage = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isEnabled = hasChanges && hasMessage && !isBusy
    }

    var title: LocalizedStringKey { mode == .commit ? "Commit" : "Commit All" }
}

/// What the sync row shows and whether pushing makes sense.
struct SyncState: Equatable {
    var upstream: String?
    var ahead: Int
    var behind: Int
    var isDetached: Bool
    var hasRemote: Bool
    var isBusy: Bool

    init(status: GitStatus, hasRemote: Bool, isBusy: Bool) {
        upstream = status.upstream
        ahead = status.ahead
        behind = status.behind
        isDetached = status.branch == nil
        self.hasRemote = hasRemote
        self.isBusy = isBusy
    }

    var isPublished: Bool { upstream != nil }

    /// Whether a push has anything to do, ignoring whether an action is already running.
    var canPublishOrPush: Bool {
        guard !isDetached else { return false }
        return isPublished ? ahead > 0 : hasRemote
    }

    var canPush: Bool { canPublishOrPush && !isBusy }

    /// Whether the primary button should offer Pull. Also true for a diverged branch: the pull fails
    /// with an explanation, which beats a push that git rejects.
    var needsPull: Bool { isPublished && !isDetached && behind > 0 }

    /// Pull fetches first, so from the menu it is useful even when the last known count is zero.
    var canPull: Bool { isPublished && !isDetached && !isBusy }
    var canFetch: Bool { hasRemote && !isBusy }

    var pushTitle: LocalizedStringKey { isPublished ? "Push" : "Publish Branch" }

    var help: LocalizedStringKey {
        if isDetached { return "HEAD is detached. Check out a branch to push." }
        if !isPublished { return hasRemote ? "Publish this branch to origin." : "This repository has no remote." }
        if behind > 0 {
            return "The branch is \(behind) behind \(upstream ?? "its upstream"). Pull first, otherwise git rejects the push."
        }
        return ahead > 0 ? "Push \(ahead) commits to \(upstream ?? "the upstream")." : "Nothing to push."
    }

    var summary: LocalizedStringKey {
        if isDetached { return "Detached HEAD" }
        guard let upstream else { return hasRemote ? "Not published" : "No remote" }
        if ahead == 0 && behind == 0 { return "Up to date with \(upstream)" }
        return "\(ahead) ahead, \(behind) behind \(upstream)"
    }
}

/// The main button under the message. Like in VS Code it commits while there are changes and
/// otherwise offers pull, push or publish. Pull and push are always in the header's sync menu too.
enum PrimaryAction: Equatable {
    case commit(CommitControl)
    case pull(commits: Int, isEnabled: Bool)
    case push(commits: Int, isEnabled: Bool)
    case publish(isEnabled: Bool)

    init(commit: CommitControl, sync: SyncState) {
        if commit.hasChanges {
            self = .commit(commit)
        } else if sync.needsPull {
            // Pull before push: git rejects a push to an upstream that has moved on.
            self = .pull(commits: sync.behind, isEnabled: sync.canPull)
        } else if sync.canPublishOrPush {
            self = sync.isPublished
                ? .push(commits: sync.ahead, isEnabled: sync.canPush)
                : .publish(isEnabled: sync.canPush)
        } else {
            // Nothing to do. A disabled Commit looks less alarming than a disabled Push.
            self = .commit(commit)
        }
    }

    var isEnabled: Bool {
        switch self {
        case .commit(let control): control.isEnabled
        case .pull(_, let isEnabled), .push(_, let isEnabled), .publish(let isEnabled): isEnabled
        }
    }

    var activity: ChangesModel.Activity {
        switch self {
        case .commit: .commit
        case .pull: .pull
        case .push, .publish: .push
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .commit(let control): control.title
        case .pull(let commits, _): "Pull ^[\(commits) Commit](inflect: true)"
        case .push(let commits, _): "Push ^[\(commits) Commit](inflect: true)"
        case .publish: "Publish Branch"
        }
    }

    /// Up for push, down for pull.
    var wiggle: WiggleSymbolEffect {
        switch self {
        case .pull: .wiggle.down
        case .commit, .push, .publish: .wiggle.up
        }
    }

    var symbol: String? {
        switch self {
        case .commit: nil
        case .pull: "arrow.down"
        case .push: "arrow.up"
        case .publish: "icloud.and.arrow.up"
        }
    }
}

struct PullRequestLookup: Equatable {
    enum Outcome: Equatable {
        case none
        case found(GitPullRequest)
        case unavailable
    }

    var branch: String
    var outcome: Outcome
}

extension GitPullRequest {
    var symbol: String { state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull" }

    var color: Color {
        switch state {
        case .open: isDraft ? .gray : .green
        case .merged: .purple
        case .closed: .red
        }
    }
}

/// Pinned under the file list: message, the primary action and the pull request control.
struct CommitArea: View {
    @Bindable var model: ChangesModel
    /// Set by the host (the Commit… command) to put the cursor in the message field.
    @Binding var focusRequest: Bool
    @FocusState private var messageFocused: Bool

    var body: some View {
        let action = model.primaryAction

        VStack(alignment: .leading, spacing: 8) {
            TextField("Commit message", text: $model.message, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($messageFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .disabled(model.activity == .commit)
                // `initial` too: the request usually arrives while the Changes tab is still being built.
                .onChange(of: focusRequest, initial: true) {
                    guard focusRequest else { return }
                    messageFocused = true
                    focusRequest = false
                }

            Button(action: model.performPrimaryAction) {
                HStack(spacing: 6) {
                    if let symbol = action.symbol {
                        Image(systemName: symbol)
                            .symbolEffect(action.wiggle, options: .repeat(.continuous), isActive: model.activity == action.activity)
                            .contentTransition(.symbolEffect(.replace))
                    } else if model.activity == action.activity {
                        ProgressView().controlSize(.small)
                    }
                    Text(action.title)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!action.isEnabled)
            // Only while the field is focused and the button commits, so Cmd-Return never pushes.
            .keyboardShortcut(messageFocused && action.activity == .commit ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .help(help(for: action))
            .contentTransition(.interpolate)
            .animation(.smooth(duration: 0.2), value: action)

            pullRequestButton
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func help(for action: PrimaryAction) -> LocalizedStringKey {
        switch action {
        case .commit(let control): control.mode == .commitAll ? "Stages all changes, then commits them." : "Commits the staged changes."
        case .pull: "Fast-forwards to \(model.syncState.upstream ?? "the upstream"). Never merges or rebases."
        case .push, .publish: model.syncState.help
        }
    }

    @ViewBuilder
    private var pullRequestButton: some View {
        if let pullRequest = model.pullRequest {
            Button {
                NSWorkspace.shared.open(pullRequest.url)
            } label: {
                Label {
                    Text("PR #\(pullRequest.number)")
                } icon: {
                    Image(systemName: pullRequest.symbol).foregroundStyle(pullRequest.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glass)
            .help(pullRequest.title)
        }
    }
}

/// Pull, push and fetch in the header next to Refresh, similar to Xcode's Integrate menu.
/// The label shows the ahead/behind counts.
struct SyncMenu: View {
    let model: ChangesModel

    var body: some View {
        let sync = model.syncState

        Menu {
            Button("Pull", systemImage: "arrow.down", action: model.pull)
                .disabled(!sync.canPull)
            Button(sync.pushTitle, systemImage: sync.isPublished ? "arrow.up" : "icloud.and.arrow.up", action: model.push)
                .disabled(!sync.canPush)
            Divider()
            Button("Fetch", systemImage: "arrow.triangle.2.circlepath", action: model.fetch)
                .disabled(!sync.canFetch)
        } label: {
            label(sync)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(sync.isDetached && !sync.canFetch)
        .help(sync.summary)
        .accessibilityLabel("Sync")
        .accessibilityValue(Text(sync.summary))
    }

    @ViewBuilder
    private func label(_ sync: SyncState) -> some View {
        // Commit progress already shows on the bottom button.
        if let activity = model.activity, activity != .commit {
            ActivitySymbol(activity: activity)
        } else if sync.ahead > 0 || sync.behind > 0 {
            HStack(spacing: 4) {
                if sync.behind > 0 { Label(String(sync.behind), systemImage: "arrow.down") }
                if sync.ahead > 0 { Label(String(sync.ahead), systemImage: "arrow.up") }
            }
            .labelStyle(.compact)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.smooth, value: sync)
        } else {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

/// Shown instead of a spinner while a remote action runs.
private struct ActivitySymbol: View {
    let activity: ChangesModel.Activity

    var body: some View {
        switch activity {
        case .fetch:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate.clockwise.wholeSymbol, options: .repeat(.continuous))
        case .pull:
            Image(systemName: "arrow.down")
                .symbolEffect(.wiggle.down, options: .repeat(.continuous))
        case .push, .commit:
            Image(systemName: "arrow.up")
                .symbolEffect(.wiggle.up, options: .repeat(.continuous))
        }
    }
}

/// Tight spacing so "↓2 ↑1" reads as one indicator.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { .init() }
}

#if DEBUG
@MainActor
private func previewCommitArea(_ title: String, _ model: ChangesModel) -> some View {
    PreviewVariant(title) {
        CommitArea(model: model, focusRequest: .constant(false))
    }
}

#Preview("Commit") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            previewCommitArea("Staged changes, no message", .previewSample(PreviewSamples.stagedOnly))
            previewCommitArea("Staged changes, message", .previewSample(PreviewSamples.stagedOnly, message: "Fix the session switcher"))
            previewCommitArea("Nothing staged: commits everything", .previewSample(PreviewSamples.unstagedOnly, message: "Fix the session switcher"))
            previewCommitArea("Long message", .previewSample(
                PreviewSamples.stagedOnly,
                message: "Fix the session switcher\n\nThe list kept sessions that had already closed, so picking one opened an empty pane. Forget a session as soon as its process exits."
            ))
            previewCommitArea("Committing", .previewSample(PreviewSamples.stagedOnly, message: "Fix the session switcher", activity: .commit))
        }
        .padding(.vertical)
    }
    .frame(width: 300, height: 640)
    .background(Color.inspectorBackground)
}

#Preview("Sync and Pull Request") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            previewCommitArea("Clean, up to date", .previewSample(PreviewSamples.synced()))
            previewCommitArea("Behind", .previewSample(PreviewSamples.synced(ahead: 2, behind: 3)))
            previewCommitArea("Ahead, open pull request", .previewSample(PreviewSamples.synced(ahead: 1), pullRequest: PreviewSamples.pullRequest(.open)))
            previewCommitArea("Pushing, draft pull request", .previewSample(
                PreviewSamples.synced(ahead: 2), activity: .push, pullRequest: PreviewSamples.pullRequest(.open, isDraft: true)
            ))
            previewCommitArea("Not published", .previewSample(PreviewSamples.synced(upstream: nil)))
            previewCommitArea("Merged pull request", .previewSample(PreviewSamples.synced(), pullRequest: PreviewSamples.pullRequest(.merged)))
        }
        .padding(.vertical)
    }
    .frame(width: 300, height: 760)
    .background(Color.inspectorBackground)
}

#Preview("Sync and Pull Request, Dark") {
    VStack(alignment: .leading, spacing: 8) {
        previewCommitArea("Ahead, open pull request", .previewSample(PreviewSamples.synced(ahead: 1), pullRequest: PreviewSamples.pullRequest(.open)))
        previewCommitArea("Staged changes, message", .previewSample(PreviewSamples.stagedOnly, message: "Fix the session switcher"))
    }
    .padding(.vertical)
    .frame(width: 300)
    .background(Color.inspectorBackground)
    .preferredColorScheme(.dark)
}

#Preview("Sync Menu") {
    VStack(alignment: .leading, spacing: 12) {
        PreviewVariant("Up to date") { SyncMenu(model: .previewSample(PreviewSamples.synced())) }
        PreviewVariant("2 ahead, 3 behind") { SyncMenu(model: .previewSample(PreviewSamples.synced(ahead: 2, behind: 3))) }
        PreviewVariant("Fetching") { SyncMenu(model: .previewSample(PreviewSamples.synced(), activity: .fetch)) }
        PreviewVariant("Pulling") { SyncMenu(model: .previewSample(PreviewSamples.synced(behind: 3), activity: .pull)) }
        PreviewVariant("Detached, no remote") { SyncMenu(model: .previewSample(PreviewSamples.synced(upstream: nil, branch: nil), hasRemote: false)) }
    }
    .padding()
}
#endif
