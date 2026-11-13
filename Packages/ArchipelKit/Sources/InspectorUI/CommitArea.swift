import AppKit
import GitKit
import SwiftUI

/// What the primary button says and whether it can be pressed.
struct CommitControl: Equatable {
    enum Mode: Equatable { case commit, commitAll }

    var mode: Mode
    var isEnabled: Bool

    init(status: GitStatus, message: String, isBusy: Bool) {
        // With nothing staged, "Commit All" is the only thing a commit can mean.
        mode = status.staged.isEmpty ? .commitAll : .commit
        let hasChanges = !status.staged.isEmpty || !status.unstaged.isEmpty
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

    var pushTitle: LocalizedStringKey { isPublished ? "Push" : "Publish Branch" }

    var help: LocalizedStringKey {
        if isDetached { return "HEAD is detached. Check out a branch to push." }
        if !isPublished { return hasRemote ? "Publish this branch to origin." : "This repository has no remote." }
        if behind > 0 {
            return "The branch is \(behind) behind \(upstream ?? "its upstream"). Pull or rebase first, otherwise git rejects the push."
        }
        return ahead > 0 ? "Push \(ahead) commits to \(upstream ?? "the upstream")." : "Nothing to push."
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

/// The pull request button: absent, an existing PR, or the create action.
enum PullRequestControl: Equatable {
    case hidden
    case existing(GitPullRequest)
    case create(isEnabled: Bool, help: LocalizedStringKey)

    init(status: GitStatus, hasRemote: Bool, hasGitHub: Bool, lookup: PullRequestLookup?, isBusy: Bool) {
        // A result for another branch says nothing about this one, and an unknown result stays hidden
        // so the button does not flicker in and out.
        guard hasGitHub, let branch = status.branch, let lookup, lookup.branch == branch else {
            self = .hidden
            return
        }
        switch lookup.outcome {
        case .unavailable:
            self = .hidden
        case .found(let pullRequest):
            self = .existing(pullRequest)
        case .none:
            let published = status.upstream != nil
            let possible = published || hasRemote
            let help: LocalizedStringKey = if !possible {
                "This repository has no remote."
            } else if !published || status.ahead > 0 {
                "Pushes the branch, then opens the pull request page in the browser."
            } else {
                "Opens the pull request page in the browser."
            }
            self = .create(isEnabled: possible && !isBusy, help: help)
        }
    }
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

/// Pinned under the file list: message, commit button, sync state and pull request control.
struct CommitArea: View {
    @Bindable var model: ChangesModel
    @FocusState private var messageFocused: Bool

    var body: some View {
        let commit = model.commitControl
        let sync = model.syncState

        VStack(alignment: .leading, spacing: 8) {
            TextField("Commit message", text: $model.message, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($messageFocused)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                .disabled(model.activity == .commit)

            Button(action: model.commit) {
                HStack(spacing: 6) {
                    if model.activity == .commit { ProgressView().controlSize(.small) }
                    Text(commit.title)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!commit.isEnabled)
            // Scoped to the focused field so Cmd-Return elsewhere in the window is left alone.
            .keyboardShortcut(messageFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .help(commit.mode == .commitAll ? "Stages all changes, then commits them." : "Commits the staged changes.")

            HStack(spacing: 6) {
                SyncSummary(sync: sync, activity: model.activity)
                Spacer(minLength: 0)
                Button(sync.pushTitle, action: model.push)
                    .disabled(!sync.canPush)
                    .help(sync.help)
            }
            .font(.callout)

            pullRequestButton
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var pullRequestButton: some View {
        switch model.pullRequestControl {
        case .hidden:
            EmptyView()
        case .existing(let pullRequest):
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
            .help(pullRequest.title)
        case .create(let isEnabled, let help):
            Button(action: model.createPullRequest) {
                HStack(spacing: 6) {
                    if model.activity == .pullRequest { ProgressView().controlSize(.small) }
                    Text("Create Pull Request")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!isEnabled)
            .help(help)
        }
    }
}

private struct SyncSummary: View {
    let sync: SyncState
    let activity: ChangesModel.Activity?

    var body: some View {
        HStack(spacing: 6) {
            if let activity {
                ProgressView().controlSize(.small)
                Text(activity.progressTitle)
            } else if sync.isDetached {
                Text("Detached HEAD")
            } else if !sync.isPublished {
                Text("Not published")
            } else if sync.ahead == 0 && sync.behind == 0 {
                Text("Up to date")
            } else {
                if sync.ahead > 0 {
                    Label(String(sync.ahead), systemImage: "arrow.up")
                        .accessibilityLabel("\(sync.ahead) ahead")
                }
                if sync.behind > 0 {
                    Label(String(sync.behind), systemImage: "arrow.down")
                        .accessibilityLabel("\(sync.behind) behind")
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(sync.upstream.map { "Tracking \($0)" } ?? "")
    }
}
