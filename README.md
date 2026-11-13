# archipel
MacOS-native agent manager with Arc style sidebar

Archipel runs CLI coding agents (Claude Code, Codex, plain shells) in embedded
Ghostty terminals. Work is grouped as Islands > Projects > Worktrees. A
worktree's content area holds tabs for agent sessions, files and diffs, and
can be split into panes shown side by side. Switching islands shows only that island's
projects. Agents in the other islands keep running, and when one needs you it
marks its island, the Dock icon and Notification Center.

## Building

Requires macOS 27, Xcode 27 and Zig 0.17 (`brew install zig`).

```sh
./scripts/build-ghostty.sh   # once, and after bumping the Ghostty tag
open Archipel.xcodeproj      # then build and run the Archipel scheme
```

The script clones Ghostty at a pinned tag into `Vendor/ghostty` and builds
`GhosttyKit.xcframework` plus Ghostty's runtime resources. Both are ignored by
git.

## Layout

- `Archipel/` - the SwiftUI app.
- `Packages/ArchipelKit` - `ArchipelCore` (model, status logic, persistence),
  `AgentKit` (agent launch commands, hook decoding, hook socket server),
  `GitKit` (async wrapper over git: status, staging, diffs, worktrees),
  `InspectorUI` (the Files and Changes sidebar), `EditorUI` (the file editor
  and the side-by-side diff view; syntax highlighting comes from highlight.js
  through the HighlighterSwift package) and the `archipel-hook` helper that
  agents call. Run `swift test` here. `editor-demo` opens an editor or diff
  in a window of its own.
- `Packages/TerminalKit` - the only code that talks to Ghostty. Includes
  `terminal-demo`, a one-window harness for testing a surface in isolation.

## How agent status works

Archipel starts each agent itself and injects what it needs per launch, so
your own agent configuration is never edited. Claude Code gets hooks through
`--settings`; Codex gets `notify` and approval notifications through `-c`
overrides. Hooks call `archipel-hook`, which forwards the event to the app over
a Unix socket in `~/Library/Application Support/Archipel`.

## Development

Set `ARCHIPEL_SUPPORT_DIR` to run a build against its own workspace file and
hook socket, next to an installed copy:

```sh
open -n --env ARCHIPEL_SUPPORT_DIR=/tmp/archipel-dev path/to/Archipel.app
```
