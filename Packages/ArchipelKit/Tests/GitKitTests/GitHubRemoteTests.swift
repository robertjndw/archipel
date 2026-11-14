import Testing
@testable import GitKit

struct GitHubRemoteTests {
    @Test(arguments: [
        "https://github.com/ghostty-org/ghostty.git",
        "https://github.com/ghostty-org/ghostty",
        "git@github.com:ghostty-org/ghostty.git",
        "ssh://git@github.com/ghostty-org/ghostty.git",
        "ssh://git@github.com:22/ghostty-org/ghostty.git",
        "https://user:token@GitHub.com/ghostty-org/ghostty.git\n",
    ])
    func understandsEveryRemoteForm(url: String) {
        let remote = GitHubRemote(remoteURL: url)
        #expect(remote?.owner == "ghostty-org")
        #expect(remote?.repository == "ghostty")
    }

    @Test(arguments: [
        "https://gitlab.com/group/project.git",
        "git@github.example.com:team/app.git",
        "https://github.com/only-owner",
        "/local/path/repo.git",
        "",
    ])
    func otherHostsAndShortPathsGiveNil(url: String) {
        #expect(GitHubRemote(remoteURL: url) == nil)
    }

    @Test func avatarIsTheOwnersPicture() {
        let remote = GitHubRemote(remoteURL: "git@github.com:ghostty-org/ghostty.git")
        #expect(remote?.avatarURL(size: 128)?.absoluteString == "https://github.com/ghostty-org.png?size=128")
    }
}
