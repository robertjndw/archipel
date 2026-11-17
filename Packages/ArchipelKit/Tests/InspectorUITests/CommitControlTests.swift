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
        #expect(!PrimaryAction(commit: staged, sync: SyncState(status: status(staged: [modified]), hasRemote: true, isBusy: false)).isEnabled)
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
        let staged = DiscardRequest.file(GitFileChange(path: "a.txt", kind: .added), staged: true)
        #expect(!staged.message.contains("Trash"))
        let modified = DiscardRequest.file(GitFileChange(path: "a.txt", kind: .modified), staged: false)
        #expect(modified.message == "This can't be undone.")
    }
}
