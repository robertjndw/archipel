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
