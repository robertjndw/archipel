#if DEBUG
import AgentKit
import ArchipelCore
import Foundation
import GitKit

/// Sample data for SwiftUI previews. Paths point nowhere real on purpose, so a preview never reads
/// or writes a repository on the machine it runs on.
enum PreviewFixtures {
    // Fixed ids so previews that need to point at one specific session or worktree can.
    static let claudeSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000C1A0")!
    static let codexSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
    static let shellSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000005E")!
    static let reviewSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AE")!
    static let idleSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000001D1")!

    static let mainWorktreeID = UUID(uuidString: "00000000-0000-0000-0000-0000000A0001")!
    static let featureWorktreeID = UUID(uuidString: "00000000-0000-0000-0000-0000000A0002")!
    static let fixWorktreeID = UUID(uuidString: "00000000-0000-0000-0000-0000000A0003")!
    static let blogWorktreeID = UUID(uuidString: "00000000-0000-0000-0000-0000000A0004")!

    static let appProjectID = UUID(uuidString: "00000000-0000-0000-0000-0000000B0001")!
    static let blogProjectID = UUID(uuidString: "00000000-0000-0000-0000-0000000B0002")!
    static let workIslandID = UUID(uuidString: "00000000-0000-0000-0000-0000000D0001")!
    static let personalIslandID = UUID(uuidString: "00000000-0000-0000-0000-0000000D0002")!

    static let root = URL(fileURLWithPath: "/tmp/archipel-preview", isDirectory: true)

    static let mainWorktree = Worktree(
        id: mainWorktreeID,
        path: root.appending(path: "orbit", directoryHint: .isDirectory),
        branch: "main",
        isMain: true,
        sessions: [
            Session(id: claudeSessionID, title: "Claude Code", agentTitle: "Refactor sync engine", agent: .claude),
            Session(id: shellSessionID, title: "Shell", agent: .shell),
        ]
    )

    static let featureWorktree = Worktree(
        id: featureWorktreeID,
        path: root.appending(path: "orbit-worktrees/feat-offline-mode", directoryHint: .isDirectory),
        branch: "feat/offline-mode",
        sessions: [
            Session(id: codexSessionID, title: "Codex", agentTitle: "Cache API responses", agent: .codex),
            Session(id: reviewSessionID, title: "Review", hasCustomTitle: true, agent: .claude),
        ]
    )

    static let fixWorktree = Worktree(
        id: fixWorktreeID,
        path: root.appending(path: "orbit-worktrees/fix-login-crash", directoryHint: .isDirectory),
        branch: "fix/login-crash-on-cold-start-when-keychain-is-locked",
        sessions: [Session(id: idleSessionID, title: "Claude Code", agent: .claude)]
    )

    static let blogWorktree = Worktree(
        id: blogWorktreeID,
        path: root.appending(path: "blog", directoryHint: .isDirectory),
        branch: "main",
        isMain: true
    )

    static let appProject = Project(
        id: appProjectID,
        name: "Orbit",
        folderURL: mainWorktree.path,
        worktrees: [mainWorktree, featureWorktree, fixWorktree],
        scripts: ProjectScripts(setup: "npm install", run: "npm run dev"),
        icon: .symbol("globe.europe.africa.fill")
    )

    static let blogProject = Project(
        id: blogProjectID,
        name: "Blog",
        folderURL: blogWorktree.path,
        worktrees: [blogWorktree],
        tint: .orange
    )

    static let workIsland = Island(id: workIslandID, name: "Work", symbol: "briefcase.fill", tint: .blue, projects: [appProject])
    static let personalIsland = Island(id: personalIslandID, name: "Personal", symbol: "person.crop.circle", tint: .green, projects: [blogProject])

    /// Two islands, the first with a three-worktree project and the main worktree selected.
    static let workspace = Workspace(
        islands: [workIsland, personalIsland],
        selectedIslandID: workIslandID,
        selectedWorktreeIDByIsland: [workIslandID: mainWorktreeID, personalIslandID: blogWorktreeID]
    )

    /// What a fresh install shows: one island, no projects.
    static let emptyWorkspace = Workspace()

    /// One session in every interesting state.
    static let activities: [Session.ID: SessionActivity] = [
        claudeSessionID: SessionActivity(status: .working, lastMessage: "Running the test suite"),
        codexSessionID: SessionActivity(status: .needsAttention(.permission), unread: true, lastMessage: "Allow `rm -rf build`?"),
        reviewSessionID: SessionActivity(status: .finished, unread: true, lastMessage: "Left 4 comments on SyncEngine.swift", completedTurn: true),
        shellSessionID: SessionActivity(status: .exited(code: 1)),
        idleSessionID: SessionActivity(status: .notStarted),
    ]

    static let gitSummaries: [Worktree.ID: GitSummary] = [
        mainWorktreeID: GitSummary(branch: "main", upstream: "origin/main", ahead: 0, behind: 2, changedFiles: 0),
        featureWorktreeID: GitSummary(
            branch: "feat/offline-mode", upstream: "origin/feat/offline-mode", ahead: 3, behind: 0, changedFiles: 7,
            diffStat: GitDiffStat(insertions: 214, deletions: 38)
        ),
        fixWorktreeID: GitSummary(branch: "fix/login-crash-on-cold-start-when-keychain-is-locked", upstream: nil, ahead: 1, behind: 0, changedFiles: 1),
    ]

    static let pullRequests: [Worktree.ID: PullRequestLookup] = [
        featureWorktreeID: PullRequestLookup(
            branch: "feat/offline-mode",
            pullRequest: GitPullRequest(
                number: 128, url: URL(string: "https://github.com/example/orbit/pull/128")!,
                title: "Offline mode", state: .open, isDraft: false
            ),
            checkedAt: .now
        ),
        fixWorktreeID: PullRequestLookup(
            branch: "fix/login-crash-on-cold-start-when-keychain-is-locked",
            pullRequest: GitPullRequest(
                number: 131, url: URL(string: "https://github.com/example/orbit/pull/131")!,
                title: "Fix login crash", state: .open, isDraft: true
            ),
            checkedAt: .now
        ),
    ]

    static let usage: [UsageProvider: ProviderUsage] = [
        .claude: ProviderUsage(
            provider: .claude,
            windows: [
                UsageWindow(usedPercent: 42, windowMinutes: 300, resetsAt: .now.addingTimeInterval(2 * 3600)),
                UsageWindow(usedPercent: 87, windowMinutes: 7 * 24 * 60, resetsAt: .now.addingTimeInterval(3 * 86400)),
            ],
            updatedAt: .now
        ),
        .codex: ProviderUsage(
            provider: .codex,
            windows: [UsageWindow(usedPercent: 12, windowMinutes: 300, resetsAt: .now.addingTimeInterval(4 * 3600))],
            updatedAt: .now
        ),
    ]

    static let sessionContexts: [Session.ID: SessionContext] = [
        claudeSessionID: SessionContext(
            usedTokens: 122_000, windowSize: 200_000, usedPercent: 61, outputTokens: 18_400,
            transcriptPath: nil, model: "Opus 4.5", updatedAt: .now
        ),
        reviewSessionID: SessionContext(
            usedTokens: 168_000, windowSize: 200_000, usedPercent: 84, outputTokens: 9_200,
            transcriptPath: nil, model: "Sonnet 4.5", updatedAt: .now
        ),
        idleSessionID: SessionContext(
            usedTokens: 41_000, windowSize: 1_000_000, usedPercent: 4.1, outputTokens: 2_100,
            transcriptPath: nil, model: "Sonnet 4.5", updatedAt: .now.addingTimeInterval(-3 * 3600)
        ),
    ]

    static let promptCaches: [Session.ID: PromptCacheState] = [
        claudeSessionID: PromptCacheState(lastRequestAt: .now.addingTimeInterval(-20), ttl: 3600),
        reviewSessionID: PromptCacheState(lastRequestAt: .now.addingTimeInterval(-12 * 60), ttl: 3600),
        idleSessionID: PromptCacheState(lastRequestAt: .now.addingTimeInterval(-3 * 3600), ttl: 300),
    ]
}

extension AppModel {
    /// The fully populated sample: two islands, sessions in every state, git status, a PR and usage.
    static func preview() -> AppModel {
        let model = AppModel(preview: PreviewFixtures.workspace, activities: PreviewFixtures.activities)
        model.gitSummaries = PreviewFixtures.gitSummaries
        model.pullRequests = PreviewFixtures.pullRequests
        model.usage = PreviewFixtures.usage
        model.sessionContexts = PreviewFixtures.sessionContexts
        model.promptCaches = PreviewFixtures.promptCaches
        return model
    }

    /// Like `preview()`, but the main worktree's Claude session failed to start.
    static func launchFailurePreview() -> AppModel {
        let model = AppModel(
            preview: PreviewFixtures.workspace,
            activities: PreviewFixtures.activities,
            launchFailures: [PreviewFixtures.claudeSessionID: "Could not find `claude` on your PATH."]
        )
        model.gitSummaries = PreviewFixtures.gitSummaries
        return model
    }

    /// A fresh install: one empty island and nothing running.
    static func emptyPreview() -> AppModel {
        let model = AppModel(preview: PreviewFixtures.emptyWorkspace)
        // Otherwise the stored default would show this Mac's real usage.
        model.usage = [:]
        return model
    }
}
#endif
