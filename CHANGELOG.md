# Changelog

All notable changes to `vch` are recorded here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/).

The English README is the source of truth; localized READMEs may lag.

## [Unreleased]

### Added
- `vch new <name> --exec "<cmd>"` — once the new worktree is ready,
  hand off to `/bin/sh -c "<cmd>"` via `execve`, replacing vch with the
  agent. Restores parity with the README, which has documented this
  flag since v0.1.0. This is the **only** AI-agent integration point
  per AGENTS.md rule #2 ("BYO Agent").
- `vch open [<name>] [--with <ide>]` — launch an IDE on a task's
  worktree. Auto-detects `*.xcworkspace` / `*.xcodeproj` /
  `Package.swift` (Xcode for project files, VS Code otherwise).
  `--with` accepts `xcode`, `code`/`vscode`, `cursor`, or any app name
  (passed to `open -a`). With no `<name>`, infers the task from the
  worktree containing `$PWD`. Override the default with
  `VCH_OPEN_DEFAULT`.
- `WorkspaceLocator.resolveCurrent(cwd:)` — public Core helper that
  returns `(workspace, taskName?)` from any cwd inside a vch-managed
  worktree. Used by `vch open`'s cwd inference.
- README translations: Japanese (`README.ja.md`), Korean (`README.ko.md`),
  Traditional Chinese (`README.zh-TW.md`). Each mirrors the English
  README 1:1; the language switcher at the top of every README is now
  unified across all five locales.

### Changed
- Reserved subcommand list now includes `open` (previously: `new list
  ls path exec build test sim remove rm repair doctor shellenv version
  help`). `vch new open` is rejected at parse time.

### Tests
- 21 new `OpenServiceTests` covering project-kind detection, IDE
  selection priority (explicit > env > auto), and argv assembly across
  all IDE × project-kind combinations.
- 9 new `WorkspaceLocatorIntegrationTests` against a real
  `/usr/bin/git` in a temp dir — closes a long-standing gap where
  `WorkspaceLocator` had **zero** test coverage.

### CI
- Upgrade `actions/checkout`, `actions/cache`, `actions/upload-artifact`,
  and the SwiftyLab/setup-swift action to their Node-24 majors. The
  Node-20 deprecation annotations going forward are now silent.

## [0.1.1] — 2026-05-06

### Added
- `vch ls` alias for `vch list`, `vch rm` alias for `vch remove`. The
  reserved-name list grew accordingly so `vch new ls` is rejected.

### Fixed
- **`vch <name>` (sugar) no longer hangs.** The previous implementation
  used `Foundation.Process()` to fork+wait the user's `$SHELL`, which
  inherited `SIG_IGN` for SIGINT/SIGQUIT and never received the
  controlling tty. The interactive shell came up "alive but deaf" —
  Ctrl-C was eaten by vch, and there was no foreground process group
  for tty signals. `vch exec` is now `execve`-replace: vch becomes the
  child, same pid/pgrp/tty, default signal dispositions.
- `vch build` / `vch test` continue to fork+wait because they need the
  child's exit duration to update `state.json`; the tty issue doesn't
  surface there because xcodebuild is non-interactive.

### Refactor
- Drop the `Mn-` milestone prefixes from source filenames. The source
  tree now reads as a normal Swift package (`TaskService.swift` rather
  than `M1-TaskService.swift`).

## [0.1.0] — 2026-05-06

Initial public release. Scope is the v1 plan locked in
`/memories/repo/vibechard-plan.md`.

### Highlights

- **`vch new <name>`** creates a sibling worktree at `<parent>/<repo>-<name>`
  on a fresh `agent/<name>` branch with isolated `.vch/` and
  `.agent-build/` directories.
- **`vch list`** / **`vch path`** / **`vch remove`** / **`vch repair`**
  cover the lifecycle. `--force --force` allows dirty trees +
  unmerged branches; `vch repair` re-syncs `state.json` against
  `git worktree list`.
- **`vch exec <name> -- <cmd...>`** runs anything inside a task's
  worktree with isolation env active and `<wt>/.vch/bin` prepended
  to `PATH`. The bare `vch <name>` shorthand drops you into a shell.
- **`vch-xcodebuild-shim`** is a standalone binary (no Foundation, no
  third-party deps). When the shim sees `xcodebuild` on argv[0] it
  injects `-derivedDataPath`, `-clonedSourcePackagesDirPath`, and
  `-resultBundlePath` from the `VCH_*` env. `xcrun` and `swift`
  dispatch through unchanged.
- **`vch build`** / **`vch test`** invoke `xcodebuild` directly with
  the shim flags pre-set; `vch test --device` lazy-clones a per-task
  simulator and reuses it.
- **`vch sim {clone,erase,shutdown,info}`** explicitly manages the
  per-task simulator clone.
- **`vch doctor [--clean] [--json]`** scans for orphan simulator
  clones, stale state bindings, and corrupt `state.json` files.
- **`vch shellenv`** emits `vch_cd` / `vch_clean` shell helpers
  (zsh / bash).
- **Shell completion** for zsh / bash / fish via
  `vch --generate-completion-script <shell>`.
- **Homebrew formula** auto-bumped on tag push by `release.yml`.

### Locked rules (AGENTS.md)

- Apple-only — no Linux/Windows shim, no cross-platform abstractions.
- BYO Agent — no AI SDK, no AI HTTP API, no agent-specific knobs.
  `vch new --exec "<cmd>"` is the sole agent integration point.
- No telemetry, no network calls.
- Two dependencies only: `swift-argument-parser`, `swift-system`.
- Three fixed targets: `VibeChardCore`, `vch`, `vch-xcodebuild-shim`.
- No config files in v1; per-worktree state lives in `.vch/state.json`.

[Unreleased]: https://github.com/Maples7/VibeChard/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Maples7/VibeChard/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Maples7/VibeChard/releases/tag/v0.1.0
