import Testing
@testable import GitKit

struct GitSyncStateTests {
    private func sync(_ status: GitStatus?, remotes: [String]? = ["origin"], isBusy: Bool = false) -> GitSyncState {
        GitSyncState(status: status, remotes: remotes, isBusy: isBusy)
    }

    @Test func nothingSyncsBeforeTheFirstRead() {
        let state = sync(nil)
        #expect(!state.canPull)
        #expect(!state.canFetch)
        #expect(!state.canPush(from: .changesTab))
        #expect(!state.canPush(from: .command))
        #expect(!state.pushPublishes(from: .command))
    }

    @Test func aCommandPushesWithNothingAheadButTheTabDoesNot() {
        let state = sync(GitStatus(branch: "main", staged: [], unstaged: [], upstream: "origin/main"))
        #expect(state.canPush(from: .command))
        #expect(!state.canPush(from: .changesTab))
        #expect(state.pushTitle(from: .command) == "Push")

        let ahead = sync(GitStatus(branch: "main", staged: [], unstaged: [], upstream: "origin/main", ahead: 2))
        #expect(ahead.canPush(from: .command))
        #expect(ahead.canPush(from: .changesTab))
    }

    @Test func onlyTheTabPublishesABranchWhoseUpstreamWasDeleted() {
        let state = sync(GitStatus(branch: "feature", staged: [], unstaged: [], goneUpstream: "origin/feature"))
        #expect(state.canPush(from: .changesTab))
        #expect(state.pushTitle(from: .changesTab) == "Publish Branch")
        // From a menu or a batch it would recreate what a merged pull request deleted.
        #expect(!state.canPush(from: .command))
        #expect(state.pushTitle(from: .command) == "Push")
        #expect(!state.promotesPush)
        #expect(!state.canPull)
    }

    @Test func publishingNeedsARemoteThePushCanName() {
        let unpublished = GitStatus(branch: "feature", staged: [], unstaged: [])
        for surface in [GitSyncState.Surface.changesTab, .command] {
            #expect(sync(unpublished, remotes: ["origin", "fork"]).canPush(from: surface))
            #expect(sync(unpublished, remotes: ["github"]).canPush(from: surface))
            #expect(!sync(unpublished, remotes: ["github", "gitlab"]).canPush(from: surface))
            #expect(!sync(unpublished, remotes: []).canPush(from: surface))
            #expect(sync(unpublished).pushPublishes(from: surface))
        }
    }

    @Test func fetchNeedsARemoteAndTheSameAnswerEverywhere() {
        let unpublished = GitStatus(branch: "feature", staged: [], unstaged: [])
        #expect(sync(unpublished, remotes: ["github", "gitlab"]).canFetch)
        #expect(!sync(unpublished, remotes: []).canFetch)
        // Remotes not read yet: an upstream is proof enough of one.
        #expect(sync(GitStatus(branch: "main", staged: [], unstaged: [], upstream: "origin/main"), remotes: nil).canFetch)
        #expect(!sync(unpublished, remotes: nil).canFetch)
    }

    @Test func aDetachedHeadOnlyFetches() {
        let state = sync(GitStatus(branch: nil, staged: [], unstaged: [], upstream: nil))
        #expect(!state.canPull)
        #expect(!state.canPush(from: .changesTab))
        #expect(!state.canPush(from: .command))
        #expect(state.canFetch)
    }

    @Test func nothingIsOfferedWhileAnOperationRuns() {
        let state = sync(GitStatus(branch: "main", staged: [], unstaged: [], upstream: "origin/main", ahead: 1, behind: 1), isBusy: true)
        #expect(!state.canPull)
        #expect(!state.canFetch)
        #expect(!state.canPush(from: .changesTab))
        #expect(!state.canPush(from: .command))
    }
}

struct ChangedFilesTests {
    @Test func aFileStagedAndModifiedAgainCountsOnce() {
        let status = GitStatus(
            branch: "main",
            staged: [GitFileChange(path: "a.txt", kind: .modified)],
            unstaged: [
                GitFileChange(path: "a.txt", kind: .modified),
                GitFileChange(path: "new/one.txt", kind: .untracked),
                GitFileChange(path: "new/two.txt", kind: .untracked),
            ]
        )
        #expect(status.changedFiles == 3)
        #expect(GitSummary(status).changedFiles == 3)
    }
}
