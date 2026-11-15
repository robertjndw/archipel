import Foundation

public struct GitPullRequest: Equatable, Sendable {
    public var number: Int
    public var url: URL
    public var title: String
    public var state: State
    public var isDraft: Bool

    public enum State: String, Sendable {
        case open, merged, closed
    }

    public init(number: Int, url: URL, title: String, state: State, isDraft: Bool) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.isDraft = isDraft
    }
}

public struct GitHubClient: Sendable {
    private let executable: URL
    private let searchPATH: String

    /// nil when `gh` is not installed.
    public init?(searchPATH: String) {
        // The app is launched from Finder with launchd's bare PATH, so the caller's login-shell PATH is
        // searched first and the usual Homebrew locations act as a safety net.
        let directories = searchPATH.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        let found = directories
            .filter { $0.hasPrefix("/") }
            .map { URL(filePath: $0, directoryHint: .isDirectory).appending(path: "gh") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let found else { return nil }
        self.init(executable: found, searchPATH: searchPATH)
    }

    public init(executable: URL, searchPATH: String) {
        self.executable = executable
        self.searchPATH = searchPATH
    }

    /// The pull request whose head is the current branch of `folder`; nil when there is none.
    public func pullRequest(in folder: URL) async throws -> GitPullRequest? {
        let result = try await run(["pr", "view", "--json", "number,url,title,state,isDraft"], in: folder)
        guard result.status == 0 else {
            // gh has no dedicated exit code for this case, so the message is the only signal.
            if result.stderr.localizedCaseInsensitiveContains("no pull requests found") { return nil }
            throw GitError(command: "gh pr view", output: result)
        }
        return try GitHubParser.pullRequest(Data(result.stdout.utf8))
    }

    private func run(_ arguments: [String], in folder: URL) async throws -> GitProcess.Output {
        try await GitProcess.run(executable, arguments, in: folder, environment: [
            // gh shells out to git, which also needs to be findable.
            "PATH": searchPATH,
            "GH_PROMPT_DISABLED": "1",
            "NO_COLOR": "1",
            "GIT_TERMINAL_PROMPT": "0",
        ])
    }
}

enum GitHubParser {
    private struct Payload: Decodable {
        var number: Int
        var url: URL
        var title: String
        var state: String
        var isDraft: Bool
    }

    /// Decodes `gh pr view --json number,url,title,state,isDraft`.
    static func pullRequest(_ json: Data) throws -> GitPullRequest {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: json)
        } catch {
            throw GitError(message: "Unexpected output from gh: \(error.localizedDescription)")
        }
        guard let state = GitPullRequest.State(rawValue: payload.state.lowercased()) else {
            throw GitError(message: "Unknown pull request state \(payload.state)")
        }
        return GitPullRequest(number: payload.number, url: payload.url, title: payload.title, state: state, isDraft: payload.isDraft)
    }
}
