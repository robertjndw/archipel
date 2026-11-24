import Foundation
import GitKit
import Observation
import Synchronization
import Testing
@testable import InspectorUI

struct CommitControlTests {
    private let modified = GitFileChange(path: "a.txt", kind: .modified)
    private let conflict = GitFileChange(path: "b.txt", kind: .conflicted)

    private func status(staged: [GitFileChange] = [], unstaged: [GitFileChange] = []) -> GitStatus {
        GitStatus(branch: "main", staged: staged, unstaged: unstaged)
    }

    @Test func modeFollowsWhetherAnythingIsStaged() {
        #expect(CommitControl(status: status(unstaged: [modified]), message: "m", isBusy: false).mode == .commitAll)
        #expect(CommitControl(status: status(staged: [modified]), message: "m", isBusy: false).mode == .commit)
        #expect(CommitControl(status: status(staged: [modified], unstaged: [modified]), message: "m", isBusy: false).mode == .commit)
    }

    @Test func needsChangesAMessageAndNoRunningAction() {
        #expect(CommitControl(status: status(unstaged: [modified]), message: "m", isBusy: false).isEnabled)
        #expect(!CommitControl(status: status(), message: "m", isBusy: false).isEnabled)
        #expect(!CommitControl(status: status(unstaged: [modified]), message: " \n\t ", isBusy: false).isEnabled)
        #expect(!CommitControl(status: status(unstaged: [modified]), message: "m", isBusy: true).isEnabled)
    }

    @Test func anUnmergedPathDisablesCommitInEitherMode() {
        // With nothing staged, Commit All would stage the conflict markers and commit them.
        let all = CommitControl(status: status(unstaged: [modified, conflict]), message: "m", isBusy: false)
        #expect(all.hasConflicts)
        #expect(!all.isEnabled)
        let staged = CommitControl(status: status(staged: [modified], unstaged: [conflict]), message: "m", isBusy: false)
        #expect(staged.hasConflicts)
        #expect(!staged.isEnabled)
        #expect(!PrimaryAction(commit: staged, sync: SyncState(status: status(staged: [modified]), remotes: ["origin"], isBusy: false)).isEnabled)
    }
}

struct SyncStateTests {
    private let idle = CommitControl(status: GitStatus(branch: "main", staged: [], unstaged: []), message: "", isBusy: false)

    @Test func aBranchWhoseUpstreamWasDeletedCanBePublishedFromTheMenuButNotTheMainButton() {
        let status = GitStatus(branch: "feature", staged: [], unstaged: [], goneUpstream: "origin/feature")
        let sync = SyncState(status: status, remotes: ["origin"], isBusy: false)
        #expect(!sync.isPublished)
        #expect(sync.summary == "origin/feature no longer exists")
        #expect(!sync.canPull)
        // The sync menu still offers it, for a branch that is meant to go back up.
        #expect(sync.canPush)
        #expect(sync.pushTitle == "Publish Branch")
        // The main button does not: after a merged pull request one click would recreate the branch.
        #expect(PrimaryAction(commit: idle, sync: sync) == .commit(idle))
        #expect(!PrimaryAction(commit: idle, sync: sync).isEnabled)
    }

    @Test func aBranchThatWasNeverPublishedGetsPublishAsTheMainButton() {
        let unpublished = GitStatus(branch: "feature", staged: [], unstaged: [])
        #expect(PrimaryAction(commit: idle, sync: SyncState(status: unpublished, remotes: ["origin"], isBusy: false)) == .publish(isEnabled: true))

        // The clone of an empty repository: an upstream is configured but nothing was deleted.
        let pending = GitStatus(branch: "main", staged: [], unstaged: [], pendingUpstream: "upstream/main")
        let sync = SyncState(status: pending, remotes: ["origin", "upstream"], isBusy: false)
        #expect(sync.summary == "Not published")
        #expect(sync.publishRemote == "upstream")
        #expect(PrimaryAction(commit: idle, sync: sync) == .publish(isEnabled: true))
    }

    @Test func anExistingUpstreamWithNothingAheadIsUpToDate() {
        let status = GitStatus(branch: "main", staged: [], unstaged: [], upstream: "origin/main")
        let sync = SyncState(status: status, remotes: ["origin"], isBusy: false)
        #expect(sync.summary == "Up to date with origin/main")
        #expect(!sync.canPush)
        #expect(sync.canPull)
    }

    @Test func publishIsOnlyOfferedWhereThePushKnowsItsRemote() {
        let status = GitStatus(branch: "feature", staged: [], unstaged: [])
        #expect(SyncState(status: status, remotes: ["origin", "fork"], isBusy: false).canPush)
        #expect(SyncState(status: status, remotes: ["github"], isBusy: false).canPush)
        #expect(!SyncState(status: status, remotes: [], isBusy: false).canPush)

        let ambiguous = SyncState(status: status, remotes: ["github", "gitlab"], isBusy: false)
        #expect(!ambiguous.canPush)
        // Fetch needs no choice of remote, and the summary still says the branch is unpublished.
        #expect(ambiguous.canFetch)
        #expect(ambiguous.summary == "Not published")
        // With nothing to commit and nothing to publish, the button falls back to a disabled Commit.
        #expect(PrimaryAction(commit: idle, sync: ambiguous) == .commit(idle))
    }
}

@MainActor
struct CommitMessageDraftTests {
    private let drafts = CommitMessageDrafts()

    @Test func draftsAreKeptPerWorktree() {
        let first = URL(filePath: "/repo/one")
        let second = URL(filePath: "/repo/two")
        drafts.set("fix the thing", for: first)
        #expect(drafts.draft(for: first) == "fix the thing")
        #expect(drafts.draft(for: second).isEmpty)
    }

    @Test func theSameFolderSpelledDifferentlyIsOneDraft() {
        drafts.set("draft", for: URL(filePath: "/repo/one"))
        #expect(drafts.draft(for: URL(filePath: "/repo/one/")) == "draft")
        #expect(drafts.draft(for: URL(filePath: "/repo/x/../one/.")) == "draft")
    }

    @Test func draftsOfRemovedWorktreesAreForgotten() {
        let kept = URL(filePath: "/repo/one")
        let removed = URL(filePath: "/repo/two")
        drafts.set("stays", for: kept)
        drafts.set("typed for a worktree that is gone", for: removed)
        drafts.forget(except: ["/repo/one"])
        #expect(drafts.draft(for: kept) == "stays")
        // A new worktree at the same path starts with an empty field.
        #expect(drafts.draft(for: removed).isEmpty)
    }

    @Test func anEmptyMessageClearsTheDraft() {
        let root = URL(filePath: "/repo/one")
        drafts.set("draft", for: root)
        drafts.set("", for: root)
        #expect(drafts.draft(for: root).isEmpty)
    }

    @Test func anUnchangedDraftDoesNotNotifyObservers() {
        let root = URL(filePath: "/repo/one")
        drafts.set("same", for: root)
        let notified = Mutex(false)
        withObservationTracking {
            _ = drafts.draft(for: root)
        } onChange: {
            notified.withLock { $0 = true }
        }
        drafts.set("same", for: root)
        #expect(!notified.withLock { $0 })
        drafts.set("different", for: root)
        #expect(notified.withLock { $0 })
    }
}

struct DiscardRequestTests {
    @Test func bulkDiscardCountsWhatTheDialogListed() {
        let changes = [GitFileChange(path: "a", kind: .modified), GitFileChange(path: "b", kind: .untracked)]
        #expect(DiscardRequest.allUnstaged(changes).title == "Discard all 2 unstaged changes?")
    }

    @Test func eachKindOfSingleDiscardExplainsWhereTheFileGoes() {
        let untracked = DiscardRequest.file(GitFileChange(path: "dir/new.txt", kind: .untracked), staged: false)
        #expect(untracked.title == "Discard changes to new.txt?")
        #expect(untracked.message.contains("Trash"))
        // `git add -N`: unstaged and added, with no copy in git, so it goes to the Trash as well.
        let intentToAdd = DiscardRequest.file(GitFileChange(path: "new.txt", kind: .added), staged: false)
        #expect(intentToAdd.message.contains("Trash"))
        // Staged but never committed: git has no version to go back to, so the file is trashed too.
        let stagedNew = DiscardRequest.file(GitFileChange(path: "a.txt", kind: .added), staged: true)
        #expect(stagedNew.message.contains("Trash"))
        #expect(!stagedNew.message.contains("can't be undone"))
        let stagedRename = DiscardRequest.file(GitFileChange(path: "dir/new.txt", originalPath: "dir/old.txt", kind: .renamed), staged: true)
        #expect(stagedRename.message.contains("old.txt comes back"))
        #expect(stagedRename.message.contains("Trash"))
        // A staged edit of a committed file is restored from HEAD, and that is final.
        let stagedEdit = DiscardRequest.file(GitFileChange(path: "a.txt", kind: .modified), staged: true)
        #expect(!stagedEdit.message.contains("Trash"))
        #expect(stagedEdit.message.contains("can't be undone"))
        let modified = DiscardRequest.file(GitFileChange(path: "a.txt", kind: .modified), staged: false)
        #expect(modified.message == "This can't be undone.")
    }

    @Test func aStagedNestedRepositoryIsNotPromisedTheTrash() {
        // Staged as a gitlink it has no trailing slash, and discarding it only drops the entry.
        let nested = DiscardRequest.file(GitFileChange(path: "vendor/lib", kind: .added), staged: true, isFolder: true)
        #expect(!nested.message.contains("Trash"))
        #expect(nested.message.contains("removed from the index"))
        #expect(nested.message.contains("stay where they are"))
    }

    @Test func whatDiscardAllLeftOutIsDescribedAsWhatHappenedToIt() {
        #expect(ChangesModel.skippedNotice(changed: 0, gone: 0, discardedAny: true) == nil)
        #expect(ChangesModel.skippedNotice(changed: 1, gone: 0, discardedAny: true) == "1 file changed while the question was open and was not discarded.")
        #expect(ChangesModel.skippedNotice(changed: 2, gone: 0, discardedAny: false)
            == "Nothing was discarded: the files changed while the question was open. Look at them again before you discard them.")
        // Committed by the agent behind the dialog: gone from the list, with no change to go looking for.
        #expect(ChangesModel.skippedNotice(changed: 0, gone: 1, discardedAny: true) == "1 file has no unstaged changes any more and was not discarded.")
        #expect(ChangesModel.skippedNotice(changed: 0, gone: 3, discardedAny: false) == "Nothing was discarded: the files have no unstaged changes any more.")
        #expect(ChangesModel.skippedNotice(changed: 1, gone: 1, discardedAny: true)
            == "2 files changed or lost their unstaged changes while the question was open and were not discarded.")
    }

    @Test func aNestedRepositoryIsNotAChangeToDiscard() {
        let folder = GitFileChange(path: ".claude/worktrees/task/", kind: .untracked)
        #expect(!folder.isDiscardable)
        #expect(GitFileChange(path: "notes.txt", kind: .untracked).isDiscardable)
        #expect(!GitFileChange(path: "a.txt", kind: .conflicted).isDiscardable)
    }
}
