# Contributing

Bug reports, ideas and pull requests are welcome.

## Before you start

For anything bigger than a small fix, please open an issue first so we can talk
about the approach before you put time into it. Archipel is pretty opinionated
about its UI.

## Building

See [Development](README.md#development) in the README. In short:

```sh
brew install zig                 # Zig 0.17
./scripts/build-ghostty.sh       # once, and after bumping the Ghostty tag
open Archipel.xcodeproj          # build and run the Archipel scheme
```

You don't need an Apple Developer account. Builds are signed ad-hoc unless you
set up `Configs/Local.xcconfig` (see [Signing](README.md#signing)). Debug builds
run as "Archipel Dev" with their own settings, so they don't touch an installed
copy.

## Tests

```sh
cd Packages/ArchipelKit && swift test
```

CI runs these and a Debug build of the app on every pull request. Most logic
lives in `Packages/ArchipelKit` so it can be tested without the app; new
behavior there should come with tests.

### UI tests

```sh
./scripts/ui-tests.sh                                  # everything, a few minutes
./scripts/ui-tests.sh WorktreeTests                    # one class
./scripts/ui-tests.sh TabTests/testRenamingASession    # one test
```

The tests in `ArchipelUITests/` launch the real app and use it the way a person
would: they add a project, create and remove worktrees, open and split tabs,
run the command palette, stage and commit in the inspector, and check the
result in the window and with git. Run them before a pull request that changes
any of those flows, and add to them when you add one. They take over the
keyboard and the pointer while they run, so leave the Mac alone until they are
done.

They are safe to run next to a copy of Archipel you are working in. The
`ArchipelUITests` scheme builds the app in a configuration of its own
(`UITests`, a Debug build called "Archipel UI Tests" with the bundle id
`<bundle id>.uitests`), into `.build/ui-tests`. Every test starts that app
against a fresh folder under `/private/tmp` for its workspace file, hook
socket, new worktrees and fixture repositories, and points the shells, git and
agents it starts at an empty home folder, so nothing reads your dotfiles or
writes to your settings. Agent sessions run a stand-in script, never the
`claude` or `codex` installed on your Mac.

Always run them through the script or the `ArchipelUITests` scheme. The tests
refuse to launch an app that was built with any other bundle id, because
launching would quit every running app with that id.

A few things to know when writing one:

- Subclass `ArchipelUITestCase`, make the repositories you need with
  `sandbox.makeRepository(named:)`, and start the app with `launch()` or
  `launch(with:)`, which seeds the workspace file through `ArchipelCore`.
- Wait for conditions (`assertExists`, `assertGone`, `waitUntil`), never for
  time. For anything git does, ask the fixture repository.
- Look elements up through `Support/Elements.swift`. Controls the tests need
  to find carry an `accessibilityIdentifier` (`sidebar.worktree`, `pane.tab`,
  `changes.unstaged`, ...); add one when a label is not enough to tell two
  controls apart.
- If a test exposes a bug you are not fixing in the same pull request, keep the
  test and wrap the failing expectation in `XCTExpectFailure` with a comment
  that describes the bug.

CI does not run the UI tests on pull requests. They run on every push to
`main` and before a release is built. To run them for a branch, start the CI
workflow by hand: `gh workflow run ci.yml --ref <branch>`.

## Pull requests

- One change per pull request. Refactors and features are easier to review
  separately.
- Commit messages and pull request titles follow
  [Conventional Commits](https://www.conventionalcommits.org): `feat: ...`,
  `fix: ...`, `refactor: ...`, `docs: ...`, `chore: ...`, `test: ...`,
  `build: ...`, with a lowercase subject and no trailing period.
- For UI changes, add a screenshot or short recording, in light and dark mode
  if the change looks different in each.
- Every view has a SwiftUI preview. Keep it working, and add one for new views.
- Comments should explain why, not what.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
