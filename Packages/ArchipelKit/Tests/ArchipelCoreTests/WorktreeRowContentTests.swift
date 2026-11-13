import Foundation
import Testing
@testable import ArchipelCore

struct WorktreeRowContentTests {
    let feature = makeWorktree("feature-folder", branch: "feature/login")

    @Test func folderIsTheDetailWithoutActivity() {
        let row = WorktreeRowContent(worktree: feature, activity: nil, git: nil)
        #expect(row.title == "feature/login")
        #expect(row.detail == "feature-folder")
        #expect(!row.detailIsMessage)
        #expect(row.trailing == .none)
        #expect(!row.hasMetadata)
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
        let row = WorktreeRowContent(worktree: feature, activity: activity, git: nil)
        #expect(row.detail == "Allow rm -rf build?")
        #expect(row.detailIsMessage)
        #expect(row.trailing == .status(activity))
    }

    @Test func messageAfterAnUnreadFinishedTurnOnly() {
        var activity = SessionActivity(status: .finished, unread: true, lastMessage: "Done, tests pass.")
        #expect(WorktreeRowContent(worktree: feature, activity: activity, git: nil).detail == "Done, tests pass.")
        activity.markViewed()
        let read = WorktreeRowContent(worktree: feature, activity: activity, git: nil)
        #expect(read.detail == "feature-folder")
        #expect(!read.detailIsMessage)
    }

    @Test func workingAndExitedSessionsKeepTheFolder() {
        let working = SessionActivity(status: .working, unread: true, lastMessage: "old")
        #expect(WorktreeRowContent(worktree: feature, activity: working, git: nil).detail == "feature-folder")
        let exited = SessionActivity(status: .exited(code: 1), unread: true, lastMessage: "old")
        #expect(WorktreeRowContent(worktree: feature, activity: exited, git: nil).detail == "feature-folder")
    }

    @Test func blankMessageFallsBack() {
        let activity = SessionActivity(status: .needsAttention(.question), lastMessage: " \n\t ")
        let row = WorktreeRowContent(worktree: feature, activity: activity, git: nil)
        #expect(row.detail == "feature-folder")
        #expect(!row.detailIsMessage)
    }

    @Test func unreadIsEmphasized() {
        let activity = SessionActivity(status: .finished, unread: true)
        #expect(WorktreeRowContent(worktree: feature, activity: activity, git: nil).isUnread)
        #expect(!WorktreeRowContent(worktree: feature, activity: nil, git: nil).isUnread)
    }

    @Test func sessionCountWithoutActivity() {
        let worktree = makeWorktree("w", branch: "b", sessions: [makeSession("a"), makeSession("b")])
        #expect(WorktreeRowContent(worktree: worktree, activity: nil, git: nil).trailing == .sessionCount(2))
    }

    @Test func zeroValuesAreHidden() {
        let row = WorktreeRowContent(worktree: feature, activity: nil, git: WorktreeGitState(changedFiles: 0, ahead: 0, behind: 0))
        #expect(row.changedFiles == nil)
        #expect(row.ahead == nil)
        #expect(row.behind == nil)
        #expect(!row.hasMetadata)
        #expect(row.metadataAccessibilityLabel.isEmpty)
    }

    @Test func metadataAndAccessibility() {
        let git = WorktreeGitState(changedFiles: 3, ahead: 1, behind: 2, pullRequest: PullRequestBadge(number: 12, state: .draft))
        let row = WorktreeRowContent(worktree: feature, activity: nil, git: git)
        #expect(row.changedFiles == 3)
        #expect(row.ahead == 1)
        #expect(row.behind == 2)
        #expect(row.pullRequest?.title == "#12")
        #expect(row.hasMetadata)
        #expect(row.metadataAccessibilityLabel == "3 changed files, 1 commit ahead, 2 commits behind, Pull request 12, draft")
    }

    @Test func pullRequestAloneIsMetadata() {
        let git = WorktreeGitState(pullRequest: PullRequestBadge(number: 7, state: .merged))
        let row = WorktreeRowContent(worktree: feature, activity: nil, git: git)
        #expect(row.hasMetadata)
        #expect(row.metadataAccessibilityLabel == "Pull request 7, merged")
    }
}
