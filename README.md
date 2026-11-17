<div align="center">

<img src="docs/images/icon.png" width="128" alt="Archipel app icon">

# Archipel

A macOS app for running coding agents. Claude Code, Codex and plain shells run in
embedded Ghostty terminals, each in its own git worktree, with an Arc style sidebar
that shows what every agent is doing.

![macOS 27](https://img.shields.io/badge/macOS-27-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Terminal](https://img.shields.io/badge/terminal-Ghostty-3551F3)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

</div>

![Archipel with a Claude Code session next to a side-by-side diff, while the sidebar shows one agent working and one waiting for permission](docs/images/archipel-dark.png)

Running three or four agents at once usually means a pile of terminal tabs,
branches that get in each other's way and a lot of checking whether something
is done yet. In Archipel every task gets its own worktree with its own
sessions, and the sidebar shows which agents are working, waiting for you or done.

## Features

### Islands, projects and worktrees

- Work is grouped as islands > projects > worktrees. Switch islands with
  <kbd>Ctrl</kbd>+<kbd>1</kbd> to <kbd>9</kbd> or a two-finger swipe over the sidebar.
  Agents in other islands keep running, and the island gets a badge when one needs you.
  If "Switch to Desktop N" is turned on in the macOS keyboard settings, it takes
  those keys first; <kbd>Ctrl</kbd><kbd>⌘</kbd><kbd>]</kbd> and <kbd>[</kbd> still work.
- Add a worktree from one search field: pick an existing local or remote branch,
  or type a name to create a new one. Worktrees you made with `git worktree` yourself are picked
  up too.
- Switch the branch a worktree has checked out with <kbd>⇧</kbd><kbd>⌘</kbd><kbd>B</kbd>,
  from its context menu or by clicking the branch name in the Changes panel. Pick a
  local or remote branch, or type a name to create one. Uncommitted changes come
  along, and you get a warning when an agent is still working in that worktree.
- Islands and projects get an SF Symbol and a color. A project can also use an
  icon found in its repository (app icon, favicon or logo) or its owner's GitHub
  avatar.
- Each project can have a setup script that runs in new worktrees (installing
  dependencies, copying `.env`) and a run script for <kbd>⌘</kbd><kbd>R</kbd>.

### Sessions

- Agents run in [Ghostty](https://ghostty.org) terminals that use your Ghostty
  config and your login shell environment.
- After a relaunch, agents resume the conversation they were in.
- Press <kbd>Space</kbd> in the sidebar to peek at the session under the pointer
  without switching to it.
- Drop files onto a session to paste their paths.
- When an agent starts a dev server, its URL shows up as a link on the tab.

### Notifications

- A worktree row lights up when its agent finishes or asks for input.
- Notifications have Allow, Deny and Reply buttons, so you can answer an agent
  without switching to Archipel. They are held back while you share your screen.
- The Dock icon gets a badge, and the menu bar icon lists every session, the ones
  waiting for you first. <kbd>⇧</kbd><kbd>⌘</kbd><kbd>U</kbd> jumps to the next one.
- Claude sessions show how many subagents they are running.

### Reviewing and committing

![Light mode with an agent session, the file editor and the Files inspector](docs/images/archipel-light.png)

- Split the window into panes, each with tabs for sessions, files and diffs.
- Side-by-side diffs and an editor with syntax highlighting.
- Leave comments on diff lines and send them to an agent in one go.
- Stage, discard, commit, push and pull from the Changes panel. Pull only
  fast-forwards. With `gh` installed, the branch's pull request shows up there
  and in the sidebar.
- Open a worktree or file in VS Code, Cursor, Zed, Xcode or another editor.

### Status bar

- Your Claude and Codex usage limits.
- Stay Awake, which keeps the Mac (and optionally the display) from sleeping while agents work.
- CPU and memory per terminal, including processes that kept running after
  their tab was closed.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Go to island, worktree, session or command | <kbd>⌘</kbd><kbd>K</kbd> |
| Open file quickly | <kbd>⌘</kbd><kbd>P</kbd> |
| New session with your default agent | <kbd>⌘</kbd><kbd>T</kbd> |
| New session with the other agents | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd>, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Switch to recent tab | <kbd>Ctrl</kbd><kbd>Tab</kbd> |
| Next / previous tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>]</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>[</kbd> |
| Split right | <kbd>⌘</kbd><kbd>\\</kbd> |
| Switch island | <kbd>Ctrl</kbd><kbd>1</kbd>...<kbd>9</kbd> |
| Next / previous island | <kbd>Ctrl</kbd><kbd>⌘</kbd><kbd>]</kbd> / <kbd>Ctrl</kbd><kbd>⌘</kbd><kbd>[</kbd> |
| Next session needing attention | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>U</kbd> |
| Add worktree | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>N</kbd> |
| Switch branch | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>B</kbd> |
| Add project | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Run project | <kbd>⌘</kbd><kbd>R</kbd> |
| Commit | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> |
| Save all files | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd> |
| Show Files / Changes / toggle inspector | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>1</kbd> / <kbd>2</kbd> / <kbd>0</kbd> |
| Open in external editor | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>E</kbd> |

<kbd>⌘</kbd><kbd>K</kbd> belongs to the palette everywhere, so it does not clear the
terminal the way it does in other terminal apps. Use <kbd>Ctrl</kbd><kbd>L</kbd> for that.

## Installation

Download `Archipel-<version>.dmg` from the
[releases](https://github.com/robertjndw/archipel/releases) and drag Archipel into
Applications.

### From source

**Requirements:** macOS 27, Xcode 27 and Zig 0.17 (`brew install zig`). You only need
the agents you want to use: [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and/or
[Codex](https://github.com/openai/codex), plus the [GitHub CLI](https://cli.github.com)
to see pull requests.

```sh
git clone https://github.com/robertjndw/archipel.git
cd archipel
./scripts/build-ghostty.sh   # once (delete Vendor/ghostty first after a tag bump)
./scripts/install.sh         # builds a Release copy into /Applications
```

Run `./scripts/install.sh` again to update. It quits and relaunches an installed
copy that is running, and leaves it untouched if the build fails. It replaces a
copy installed from a DMG too.

Copies installed from a DMG update themselves. Beta versions can be turned on
under Settings > About.

## How agent status works

Archipel starts each agent itself and injects what it needs per launch, so your own
agent configuration is never edited. Claude Code gets hooks through `--settings`;
Codex gets `notify` and approval notifications through `-c` overrides. Hooks call
`archipel-hook`, which forwards the event to the app over a Unix socket in
`~/Library/Application Support/Archipel`.

## Development

```sh
./scripts/build-ghostty.sh   # clones Ghostty at a pinned tag and builds GhosttyKit
open Archipel.xcodeproj      # then build and run the Archipel scheme
```

The script clones Ghostty into `Vendor/ghostty` and builds
`GhosttyKit.xcframework` plus Ghostty's runtime resources. Both are ignored by git.

### Signing

The project builds without an Apple Developer account: by default everything is
signed ad-hoc ("Sign to Run Locally"). macOS then treats each rebuild as a new app
and asks again for privacy permissions such as access to `~/Documents`. To sign
with your own team, copy `Configs/Local.xcconfig.example` to `Configs/Local.xcconfig`
(ignored by git) and fill in your team ID and a bundle id prefix of your own.

### Debug builds next to an installed copy

Debug builds are a separate app, "Archipel Dev" with the bundle id
`<bundle id>.debug`. They keep their own settings and their own workspace and hook
socket in `~/Library/Application Support/Archipel Dev`, so they can run next to an
installed release without touching its data.

Set `ARCHIPEL_SUPPORT_DIR` to run a build against a throwaway workspace file and
hook socket instead. Keep the path short, because Unix socket paths
are limited to about 100 bytes and agent status stops working beyond that.

```sh
open -n --env ARCHIPEL_SUPPORT_DIR=/tmp/archipel-dev path/to/Archipel.app
```

### Project layout

- `Archipel/` - the SwiftUI app. `Model/` is `AppModel` and `AppSettings`,
  `Services/` wraps system APIs (notifications, sleep, process stats), and
  `Views/` has a folder per feature. The Xcode groups follow the folders on
  disk, so new files are picked up without touching the project.
- `Packages/ArchipelKit` - `ArchipelCore` (model, status logic, persistence),
  `AgentKit` (agent launch commands, hook decoding, hook socket server),
  `GitKit` (async wrapper over git: status, staging, diffs, branches, worktrees),
  `InspectorUI` (the Files and Changes sidebar), `EditorUI` (the file editor
  and the side-by-side diff view; syntax highlighting comes from highlight.js
  through the HighlighterSwift package), `UISupport` (view helpers those two
  share) and the `archipel-hook` helper that
  agents call. Run `swift test` here. `editor-demo` opens an editor or diff
  in a window of its own.
- `ArchipelUITests/` - end-to-end tests that drive the real app against a
  throwaway workspace and fixture git repositories. Run them with
  `./scripts/ui-tests.sh`; see [CONTRIBUTING.md](CONTRIBUTING.md#ui-tests).
- `Packages/TerminalKit` - the only code that talks to Ghostty. Includes
  `terminal-demo`, a one-window harness for testing a surface in isolation.
- `scripts/` - `build-ghostty.sh`, `install.sh`, `ui-tests.sh`, and `build-dmg.sh`,
  `notarize.sh` and `build-appcast.py`, which the release workflows use.
  Releases and in-app updates (beta and stable channels) are described in
  [docs/releasing.md](docs/releasing.md).
- `Configs/` - shared build settings and the optional `Local.xcconfig`.

## Contributing

Issues and pull requests are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md).
Please report security issues privately, see [SECURITY.md](SECURITY.md).

## Acknowledgements

The terminals are [Ghostty](https://github.com/ghostty-org/ghostty), updates come
from [Sparkle](https://sparkle-project.org) and syntax highlighting from
[highlight.js](https://highlightjs.org) through
[HighlighterSwift](https://github.com/smittytone/HighlighterSwift). Their
licenses are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md),
[`Packages/TerminalKit/THIRD_PARTY_NOTICES.md`](Packages/TerminalKit/THIRD_PARTY_NOTICES.md)
and
[`Packages/ArchipelKit/THIRD_PARTY_NOTICES.md`](Packages/ArchipelKit/THIRD_PARTY_NOTICES.md).

## License

Archipel is available under the [MIT License](LICENSE).
