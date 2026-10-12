# vscode-switcher — notes for agents

Native macOS menu bar agent (`LSUIElement`): rest the pointer on the left screen edge and a
panel slides out with the open VSCode windows, their colours, the state of the Claude Code
agents in each window, and the projects that have no window. A status item shows token usage
from the claude_gw gateway.

The full spec and every verified data format live in [docs/SPEC.md](docs/SPEC.md). Read the
relevant section before changing behaviour; README.md covers install and the signing setup.

## Layout

```text
macos/Package.swift              SPM, macOS 14, no external dependencies
macos/Sources/VSCodeSwitcher/
  Config, Model, JSONC           settings, types, tolerant JSONC parser
  WorkspaceIndex                 project scan, colours from .code-workspace
  VSCodeWindows                  Accessibility: list and focus windows
  ClaudeSessions                 live sessions, states, transcripts, subagents
  SessionProcesses               per-session processes, CPU, orphaned processes (SPEC §2.8)
  UsageModel, UsageClient        claude_gw response bodies and requests (SPEC §2.7)
  UsageIndex, UsageStore         session_id -> transcript slug, gateway polling
  FleetCapacity                  account spend against weekly replenishment (SPEC §2.7)
  DataSource                     snapshot assembly and ranking
  SnapshotStore                  main-actor cache, background refresh
  EdgeTrigger, PanelController   edge trigger, NSPanel
  SwitcherView                   SwiftUI panel (SwitcherViewModel)
  MenuBarIcon, UsagePopover      status item and its popover (SPEC §4)
macos/Tests/VSCodeSwitcherTests/ XCTest suites, including UITests.swift
hooks/claude-window-status.sh    Claude Code hook: writes ~/.claude/window-status/<session>.json
hooks/statusline.sh              statusLine: writes <session>.metrics.json
scripts/install-hooks.sh         idempotent hook install into ~/.claude/settings.json
scripts/test-hooks.sh            hook state machine tests
scripts/test-install-hooks.sh    installer tests in a sandbox HOME
macos/scripts/build.sh           builds the .app bundle
macos/scripts/make-icons.sh      icons from SVG (needs librsvg)
```

Config: `~/.config/vscode-switcher/config.json` (optional, every key has a default, invalid
keys are ignored one by one; the app never creates it). Hook env vars:
`VSCODE_SWITCHER_STATUS_DIR`, `VSCODE_SWITCHER_DEBUG` (dumps payloads to `_debug.jsonl`).

## Commands

```text
make build      release binary (cd macos && swift build -c release)
make test       swift test + scripts/test-hooks.sh + scripts/test-install-hooks.sh
make app        .app bundle
make install    install into /Applications (ditto) and launch
make run        build the bundle and launch it from macos/
make icons      regenerate icons from SVG
make hooks      install the Claude Code hooks
make dump       print the assembled model to the console (--dump)
```

The build must stay clean under `swift build -c release -Xswiftc -strict-concurrency=complete`.
After changing which hook events are subscribed, existing installs need `make hooks` again.

## Conventions

- Code comments, UI strings (panel, menus, popover, alerts, accessibility labels, tooltips)
  and commit messages (subject, body, merge commits) are English. Docs and reports to the
  user are Russian; UI strings quoted in docs stay English.
- Targeted edits; no abstractions for the future.
- File read errors never crash the app: broken JSON, a vanished file, a race with a writer are
  normal.
- Edits to files that are not ours (`~/.claude/settings.json`) go through a backup and a
  validity check of the result.

## Invariants that are easy to break

- **Transcript slug.** `~/.claude/projects/<slug>/` is the `cwd` with every character outside
  `[A-Za-z0-9-]` replaced by `-` (including `_` and `.`). It cannot be decoded back: always
  compute the slug forwards from each known project, as `DataSource` does.
- **`session_id` is not unique across `~/.claude/projects/`**: a resumed session copies its
  history under the new slug. Such spend is attributed only when the copies map to one
  project, otherwise it is `ambiguous` (see `DataSource.settle`, `UsageIndex.narrowToWindow`).
- **`cwd` means three things**: the process start directory in `~/.claude/sessions/<pid>.json`
  (the transcript lives by it), the directory at event time in a hook payload, and at record
  time in a transcript record. Sessions move between directories while running.
- **Path prefix matching needs the trailing `/`** (`asakusa_lab` vs `asakusa_lab_glaze_resolver`);
  `ProjectMatchingTests` guards it.
- **Transcripts reach tens of megabytes.** Read only the tail via `seek`
  (`transcriptTailBytes`), dropping the first partial line. Never read one whole.
- **Context limit:** never guess. Source order is in SPEC §2.4; if unprovable, `nil` and the
  raw token count. A confidently wrong percentage is worse than none.
- **Window identity** is `CGWindowID` via `_AXUIElementGetWindow` (resolved with `dlsym`), not
  z-order position. An Accessibility timeout applies to the element it was set on; use the
  system-wide element for the whole process.
- **A running agent never silently disappears**: orphan `cwd:` rows (agents outside the scan
  roots) go at the top of the projects section (SPEC §2.2.1).
- **Ordering.** Projects: mtime of the newest session transcript (not the directory mtime, not
  the session count). Windows: newest `lastActivity` across the row's sessions, not z-order
  and not `SwitcherRow.lastActivity`. Both orders are frozen while the panel is shown (SPEC §4).
  `sorted` is unstable: every sort key needs an explicit arrival-index tie-break, and tests must
  call the comparator both ways round (`DataSource.ranksAbove`), not go through `sorted`.
- **Row roll-up priority** is `blocked > active > done > asleep` (SPEC §3.1). It is not the
  `AgentState` order (`waiting` above `working`), which `rankedOrphans` relies on; do not
  change either to match the other.
- **Silence is not a stop.** A thinking subagent can write nothing for minutes, so liveness
  uses `subagentActiveSeconds` (default 600 s). A stop is read from the last record
  (`end_turn`/`stop_sequence`, or an interrupt marker that a later record can supersede).
- **A wait that was cleared by mistake does not come back**: `resolveState` overrides the hook
  only when the transcript is newer, and a blocked agent's transcript is frozen.
- **Hook wait list.** Several waits can be pending at once, so the state file keeps a `waits`
  list; `PostToolUse`/`PostToolUseFailure` clear a wait only when both `agent_id` and
  `tool_name` match (subagents report under the parent's `session_id`). The state is the max
  over the remaining waits. `AskUserQuestion` produces no `Stop`; question vs permission is
  decided by `tool_name` in `PermissionRequest` (SPEC §2.6.2, §2.6.3).
- **`PostToolUse` is a hot path** (after every successful tool call, full tool response in the
  payload): nothing expensive before the early exit, no `jq`, no debug dump. String work runs
  under `LC_ALL=C`; measure in that locale.
- **An answered question is matched by `tool_use_id`**, not by "some result came after".
- **Do not add a state or branch that cannot fire.** Verify a new state's source empirically
  (method in SPEC §2.6.2) and record negative results in the spec.
- **Directory listings may be cached by directory mtime; file timestamps may not**: appending
  to an open transcript does not move the directory mtime.
- **No `static let` on a `@MainActor` type used from `nonisolated async` code**: it pulls that
  code onto the main thread.

## Verifying hooks and the live app

- Claude Code hooks can only be verified with an interactive `claude` in a pty: headless mode
  auto-approves or denies permissions. Strip `CLAUDE*` from the child environment
  (`CLAUDE_CODE_CHILD_SESSION` disables transcript writing) and use a tool that the user's
  `allow`/`deny` lists do not cover, e.g. a sandbox project's `permissions.ask`.
- Checking on the running app is welcome, but the machine is in use: close windows you opened,
  revert settings, do not leave System Settings open, put the pointer back.
- Mutation checks: mutate a copy (`cp` to `/tmp`, take its sha256 first); never revert with
  `git checkout -- <file>` on uncommitted work. Chain restore and copy removal with `&&`,
  absolute paths only.
- Do not generate machine load to reproduce a flake; shrink the timing window instead.
- Layout claims need a render, not reasoning. `ImageRenderer` on empty content returns the
  previous rendering, so a "nothing is drawn" test must be able to fail.
- The app is signed with the self-signed `VSCodeSwitcher Dev` certificate (README), so rebuilds
  keep the Accessibility grant. Do not run `tccutil reset Accessibility
  xyz.vvzvlad.vscode-switcher` unless access is actually lost; check first with
  `defaults read xyz.vvzvlad.vscode-switcher accessibilityPromptShown` ("does not exist" means
  the app sees access).

## Git

Branch `main`, remote `origin` on the private Gitea
[projects/vscode-switcher](https://gitea.vvzvlad.xyz/projects/vscode-switcher), over HTTPS via
the credential helper (no SSH key there). Issues live in the same repository. Atomic
conventional commits.

## Limits for agents
- Tests: at most three times the code (`wc -l` of `tests/` against the code). Over the limit,
  still write the test you need, and in the same change go through the old tests: drop or merge
  duplicates and tests of implementation rather than behaviour.
- Comments explain the code as it is and why it is built this way. History ("used to", "after
  the review", "since the incident") goes into the commit message.
- This file stays under ~150 lines: only what an agent would get wrong without it. No decision
  history, incident logs or retelling of the code.
