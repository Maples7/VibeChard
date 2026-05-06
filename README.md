# VibeChard

[![Release](https://img.shields.io/github/v/release/Maples7/VibeChard?label=release&color=blue)](https://github.com/Maples7/VibeChard/releases) [![CI](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/Maples7/VibeChard?color=green)](LICENSE) ![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![Swift](https://img.shields.io/badge/swift-5.10%2B-orange)

**English** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

> **Per-task isolated worktrees for parallel Apple development with AI agents.**
> Run multiple Claude / Codex / Copilot / Cursor sessions on the same Xcode
> project without `build.db` locks, `DerivedData` thrash, or simulator
> collisions.

```sh
brew install maples7/tap/vch
```

Then, in any Apple project:

```sh
vch new add-paywall          # creates an isolated worktree + agent branch
vch add-paywall              # drops you into a shell with isolation active
                             # → run xcodebuild / swift test as usual
vch test add-paywall --device "iPhone 16"
vch remove add-paywall
```

That's it. Every agent gets its own worktree, its own `DerivedData`, its
own simulator clone — and your `~/Library/Developer/` stays untouched.

> **Status: alpha (v0.1.0).** The CLI surface is settling but not yet
> frozen; on-disk `.vch/state.json` may gain fields. Pin a tag if you
> need stability.

## Why a CLI just for this?

Generic git-worktree managers stop at "isolate the source tree." Apple's
toolchain has at least seven *more* shared resources that, when contended
by parallel `xcodebuild` runs, cause non-deterministic failures:

| Resource | What goes wrong | VibeChard's answer |
|---|---|---|
| `DerivedData` | Module rebuild thrash, stale caches | `-derivedDataPath <wt>/.agent-build/DerivedData` |
| `ModuleCache.noindex` | Clang module corruption under concurrency | `CLANG_MODULE_CACHE_PATH` per worktree |
| SwiftPM global cache | `Package.resolved` write conflicts | `-clonedSourcePackagesDirPath` per worktree |
| `xcresult` bundles | Last writer wins | `-resultBundlePath` per worktree |
| Simulator devices | Two tasks installing onto the same iPhone 16 | `xcrun simctl clone` per task |
| `xcodebuild` PATH lookup by agents | Agents bypass our flags | **PATH shim** that auto-injects flags |
| Source tree | Standard | `git worktree` + `agent/<name>` branch |

You **bring your own AI agent** — Claude, Codex, Copilot, Cursor, anything
that speaks shell. VibeChard is *not* an AI vendor wrapper. No telemetry,
no network calls, no SDK lock-in.

## Install

### Homebrew (recommended)

```sh
brew install maples7/tap/vch
```

The formula installs:

- `vch` into Homebrew's `bin/` (on `PATH`)
- `vch-xcodebuild-shim` into `libexec/` (intentionally **not** on `PATH`
  — it should only ever be reached by the symlink `vch exec` plants in
  the per-task `.vch/bin/`)
- Bash, Zsh, and Fish completions

### From source

Requirements: macOS 13+, Xcode 15.3+ (Swift 5.10+).

```sh
git clone https://github.com/maples7/VibeChard.git
cd VibeChard
swift build -c release
ln -s "$PWD/.build/release/vch" /usr/local/bin/vch    # or wherever you keep CLI bins
```

## Quickstart

From inside any git-tracked Apple project:

```sh
# 1. Spin up an isolated worktree on agent/add-paywall
vch new add-paywall

# 2. Open a shell inside it (PATH shim is active here)
vch add-paywall
# inside that shell:
#   xcodebuild build              ← gets -derivedDataPath injected automatically
#   swift test                    ← isolated module cache + SwiftPM clone dir
#   exit                          ← back to the host shell

# 3. Or run xcodebuild directly without entering the shell:
vch build add-paywall --scheme MyApp
vch test  add-paywall --scheme MyApp --device "iPhone 16"

# 4. Driving an agent inside the worktree:
vch new fix-toast --exec "claude"     # spawns claude inside the isolated worktree
vch new triage --copy-untracked       # also bring over .env / .vscode / etc.
vch exec fix-toast -- npm run lint    # one-shot command in the worktree

# 5. Inspect & clean up
vch list
vch path add-paywall                  # absolute path of the worktree
vch remove add-paywall                # deletes worktree + branch + sim clone
```

## Commands

| Command | What it does |
|---|---|
| `vch new <name>` | Create worktree at `../<repo>-<name>` on branch `agent/<name>`. `--exec "<cmd>"` runs a command inside it (e.g. an AI agent). `--copy-untracked` also copies git-untracked, non-ignored files (e.g. `.env`, `.vscode/settings.json`) from the main worktree. |
| `vch list` | List all tasks in the current workspace. `--json` for machine output; `-v`/`--verbose` adds `BASE` + `PATH` columns. |
| `vch path <name>` | Print the absolute path of a task's worktree. |
| `vch state <name>` | Pretty-print `.vch/state.json` for a task. `--json` for the raw file contents. |
| `vch open [<name>] [--with <ide>]` | Open the worktree in an IDE. Auto-detects `*.xcworkspace` / `*.xcodeproj` / `Package.swift` (Xcode for project files, VS Code otherwise). `--with` accepts `xcode`, `code`/`vscode`, `cursor`, or any app name (passed to `open -a`). Override default with `VCH_OPEN_DEFAULT`. With no `<name>`, uses the worktree containing `$PWD`. |
| `vch <name>` | Sugar for `vch exec <name> -- $SHELL` — drops you into a shell with isolation env vars + `.vch/bin` PATH shim active. |
| `vch exec <name> -- <cmd...>` | Run any command inside a task's worktree with isolation active. |
| `vch build <name> [flags] [-- xcodebuild-extras]` | `xcodebuild build` against the task's worktree, with `-derivedDataPath` / `-clonedSourcePackagesDirPath` injected. |
| `vch test  <name> [flags] [-- xcodebuild-extras]` | `xcodebuild test` against the task's worktree, with `-resultBundlePath` injected; lazy-clones a simulator on first `--device` and reuses it after. |
| `vch sim {clone,erase,shutdown,info} <name>` | Manage the per-task simulator clone explicitly. |
| `vch remove <name> [--force [--force]] [--keep-sim]` | Delete the worktree, branch, and (by default) simulator clone. Two `--force`s allow dirty trees + unmerged branches. |
| `vch repair` | Re-sync `.vch/state.json` with what `git worktree list` actually shows. |
| `vch doctor [--clean] [--json]` | Detect orphan simulator clones, stale state bindings, and corrupt `state.json`s. Exits non-zero on any finding. |
| `vch shellenv` | Emit `vch_cd` / `vch_new` / `vch_clean` shell helpers (bash/zsh). |
| `vch completions install [--shell <s>]` | Install the completion script for `zsh` / `bash` / `fish` (auto-detected from `$SHELL`). `--print` previews; `--force` overwrites. |
| `vch version` | Print version + toolchain info (`--json` for machine-readable). |

All commands that take a `<name>` complete it from the current
workspace — install completions and hit `<TAB>`.

## How isolation works

Inside a task's worktree, `<wt>/.vch/bin/` is prepended to `PATH`, and
contains symlinks `xcodebuild`, `xcrun`, `swift` → `vch-xcodebuild-shim`.

The shim reads three env vars (`VCH_DERIVED_DATA_PATH`,
`VCH_SPM_CLONE_DIR`, `VCH_RESULT_BUNDLE_PATH`), injects matching flags
into the `xcodebuild` argv if the user hasn't already passed them,
`mkdir -p`'s the directories, then `execv`'s the real binary resolved
via `/usr/bin/xcrun -f xcodebuild` (bypasses `PATH`, no recursion). For
`xcrun` and `swift` the shim is a transparent passthrough.

Result: any tool an agent might run — `xcodebuild`, `swift test`,
`Tuist`, custom scripts, anything that calls `xcodebuild` internally —
gets isolated automatically. No flag-passing required.

`vch build` and `vch test` skip the PATH shim and call `xcodebuild`
directly with the same flags, since they know the args at the call site.

## Configuration

None. All per-task state lives at `<worktree>/.vch/state.json`. There
are no `~/.vchrc`, no `.vch.toml`, no global config files. The only
runtime knobs are the `VCH_*` env vars listed above (typically set by
`vch exec` itself; you rarely set them by hand).

## What VibeChard is not

- **Not an AI vendor wrapper.** No SDK, no API key, no model
  abstraction. Use whatever agent you like — VibeChard just makes
  parallel sessions safe.
- **Not cross-platform.** Apple-only by design. The whole point is
  depth on the Xcode toolchain.
- **Not a CI orchestrator.** It runs locally, in your terminal,
  against worktrees on your disk. CI matrices are a different
  problem.

## Build & test from source

```sh
swift build -c release
./.build/release/vch version
swift test --parallel             # 116 tests, ~9s on M-series
```

CI runs the same commands plus a shim smoke probe on every push:
[.github/workflows/ci.yml](.github/workflows/ci.yml).

## License

[Apache-2.0](LICENSE). No CLA. No telemetry. No network calls.
