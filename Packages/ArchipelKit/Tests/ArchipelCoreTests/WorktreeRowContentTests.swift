import Foundation
import Testing
@testable import ArchipelCore

struct WorktreeRowContentTests {
    let feature = makeWorktree("feature-folder", branch: "feature/login")

    @Test func folderIsTheDetailWithoutAnythingElse() {
        let row = WorktreeRowContent(worktree: feature, activity: nil, git: nil)
        #expect(row.title == "feature/login")
        #expect(row.metadata == [.folder("feature-folder")])
        #expect(row.trailing == .none)
    }

    @Test func folderIsDroppedWhenItRepeatsTheBranchOrOtherMetadataExists() {
        let same = makeWorktree("fix", branch: "fix")
        #expect(WorktreeRowContent(worktree: same, activity: nil, git: nil).detail == nil)
        let row = WorktreeRowContent(worktree: feature, activity: nil, git: WorktreeGitState(ahead: 1))
        #expect(row.metadata == [.aheadBehind(ahead: 1, behind: 0)])
    }

    @Test func mainCheckoutAndBranchlessFolderHaveNoFolderDetail() {
        let main = makeWorktree("app", isMain: true, branch: "main")
        #expect(WorktreeRowContent(worktree: main, activity: nil, git: nil).detail == nil)
        let plain = makeWorktree("notes")
        let row = WorktreeRowContent(worktree: plain, activity: nil, git: nil)
        #expect(row.title == "notes")
        #expect(row.detail == nil)
    }

    @Test func messageWhileNeedingTheUser() {
        let activity = SessionActivity(status: .needsAttention(.permission), unread: false, lastMessage: "Allow\n  rm -rf build?")
        let row = WorktreeRowContent(worktree: feature, activity: activity, git: WorktreeGitState(changedFiles: 2))
        #expect(row.detail == .message("Allow rm -rf build?", needsUser: true))
        #expect(row.metadata.isEmpty)
        #expect(row.trailing == .status(activity))
    }

    @Test func messageAfterAnUnreadFinishedTurnOnly() {
        var activity = SessionActivity(status: .finished, unread: true, lastMessage: "Done, tests pass.")
        #expect(WorktreeRowContent(worktree: feature, activity: activity, git: nil).detail == .message("Done, tests pass.", needsUser: false))
        activity.markViewed()
        let read = WorktreeRowContent(worktree: feature, activity: activity, git: nil)
        #expect(read.metadata == [.folder("feature-folder")])
    }

    @Test func messagesCanBeTurnedOff() {
        let activity = SessionActivity(status: .needsAttention(.question), lastMessage: "Which one?")
        let row = WorktreeRowContent(worktree: feature, activity: activity, git: nil, options: .init(showsMessages: false))
        #expect(row.metadata == [.folder("feature-folder")])
        #expect(row.trailing == .status(activity))
    }

    @Test func workingAndExitedSessionsKeepTheMetadata() {
        let working = SessionActivity(status: .working, unread: true, lastMessage: "old")
        #expect(WorktreeRowContent(worktree: feature, activity: working, git: nil).metadata == [.folder("feature-folder")])
        let exited = SessionActivity(status: .exited(code: 1), unread: true, lastMessage: "old")
        #expect(WorktreeRowContent(worktree: feature, activity: exited, git: nil).metadata == [.folder("feature-folder")])
    }

    @Test func blankMessageFallsBack() {
        let activity = SessionActivity(status: .needsAttention(.question), lastMessage: " \n\t ")
        let row = WorktreeRowContent(worktree: feature, activity: activity, git: nil)
        #expect(row.metadata == [.folder("feature-folder")])
    }

    @Test func unreadIsEmphasized() {
        let activity = SessionActivity(status: .finished, unread: true)
        #expect(WorktreeRowContent(worktree: feature, activity: activity, git: nil).isUnread)
        #expect(!WorktreeRowContent(worktree: feature, activity: nil, git: nil).isUnread)
    }

    @Test func zeroValuesAreHidden() {
        let main = makeWorktree("app", isMain: true, branch: "main")
        let row = WorktreeRowContent(worktree: main, activity: nil, git: WorktreeGitState())
        #expect(row.detail == nil)
        #expect(row.metadataAccessibilityLabel.isEmpty)
    }

    @Test func metadataOrderAndAccessibility() {
        let worktree = makeWorktree("w", branch: "b", sessions: [makeSession("a")])
        let git = WorktreeGitState(changedFiles: 3, ahead: 1, behind: 2, insertions: 10, deletions: 1,
                                   pullRequest: PullRequestBadge(number: 12, state: .draft))
        let row = WorktreeRowContent(worktree: worktree, activity: nil, git: git)
        #expect(row.metadata == [
            .pullRequest(PullRequestBadge(number: 12, state: .draft)),
            .diff(insertions: 10, deletions: 1),
            .changedFiles(3),
            .aheadBehind(ahead: 1, behind: 2),
        ])
        #expect(row.metadataAccessibilityLabel
            == "Pull request 12, draft, 10 lines added, 1 line removed, 3 changed files, 1 commit ahead, 2 commits behind")
    }

    @Test func narrowVariantsDropTheLeastImportantFirstAndKeepOrder() {
        let worktree = makeWorktree("w", branch: "b", sessions: [makeSession("a")])
        let git = WorktreeGitState(changedFiles: 3, ahead: 1, insertions: 10, deletions: 1,
                                   pullRequest: PullRequestBadge(number: 12, state: .open))
        guard case .metadata(let variants) = WorktreeRowContent(worktree: worktree, activity: nil, git: git).detail else {
            Issue.record("expected metadata")
            return
        }
        let pr = WorktreeRowContent.MetadataItem.pullRequest(PullRequestBadge(number: 12, state: .open))
        let diff = WorktreeRowContent.MetadataItem.diff(insertions: 10, deletions: 1)
        let ahead = WorktreeRowContent.MetadataItem.aheadBehind(ahead: 1, behind: 0)
        #expect(variants == [
            [pr, diff, .changedFiles(3), ahead],
            [pr, diff, ahead],
            [pr, diff],
            [pr],
        ])
    }

    @Test func optionsHideGitAndPullRequests() {
        let git = WorktreeGitState(changedFiles: 3, insertions: 4, pullRequest: PullRequestBadge(number: 7, state: .merged))
        let noGit = WorktreeRowContent(worktree: feature, activity: nil, git: git, options: .init(showsGitStatus: false))
        #expect(noGit.metadata == [.pullRequest(PullRequestBadge(number: 7, state: .merged))])
        let noPR = WorktreeRowContent(worktree: feature, activity: nil, git: git, options: .init(showsPullRequests: false))
        #expect(noPR.metadata == [.diff(insertions: 4, deletions: 0), .changedFiles(3)])
    }

    @Test func agentIconOnlyForASingleSession() {
        let two = makeWorktree("w", branch: "b", sessions: [makeSession("a"), makeSession("b")])
        #expect(WorktreeRowContent(worktree: two, activity: nil, git: nil).agent == nil)
        let one = makeWorktree("w", branch: "b", sessions: [makeSession("a")])
        let row = WorktreeRowContent(worktree: one, activity: nil, git: nil)
        #expect(row.agent == .claude)
        // The agent no longer takes the second line, so the folder gets it.
        #expect(row.metadata == [.folder("w")])
    }

    @Test func sessionRowsOnlyForSeveralSessions() {
        let a = makeSession("a"), b = makeSession("b")
        let single = makeWorktree("w", sessions: [a])
        #expect(SessionRowContent.rows(for: single, activities: [:], focusedSessionID: a.id).isEmpty)

        let working = SessionActivity(status: .working)
        let worktree = makeWorktree("w", sessions: [a, b])
        let rows = SessionRowContent.rows(for: worktree, activities: [b.id: working], focusedSessionID: b.id)
        #expect(rows.map(\.id) == [a.id, b.id])
        #expect(rows.map(\.title) == ["a", "b"])
        #expect(rows[0].activity == SessionActivity())
        #expect(rows[1].activity == working)
        #expect(rows.map(\.isFocused) == [false, true])
    }
}
