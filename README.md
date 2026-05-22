# VibeChard

[![Release](https://img.shields.io/github/v/release/Maples7/VibeChard?label=release&color=blue)](https://github.com/Maples7/VibeChard/releases) [![CI](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/Maples7/VibeChard?color=green)](LICENSE) [![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FMaples7%2FVibeChard%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Maples7/VibeChard) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FMaples7%2FVibeChard%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Maples7/VibeChard)

**English** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

<p align="center">
  <a href="docs/images/hero.en.png"><img src="docs/images/hero.en.png" alt="Without vch: 3 parallel xcodebuilds collide on build.db / module cache / simulator. With vch: each agent in its own worktree with isolated DerivedData and sim clone." width="960"></a>
</p>

> **Per-task isolated worktrees for parallel Apple development with AI agents.**
> Run multiple Claude / Codex / Copilot / Cursor sessions on the same Xcode
> project without `build.db` locks, `DerivedData` thrash, or simulator
> collisions.

```sh
brew install maples7/tap/vch
```

<p align="center">
  <img src="docs/images/demo.gif" alt="vch new → vch list → vch state → vch exec → vch remove, all isolated, in 25 seconds" width="720">
</p>

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

<p align="center">
  <img src="docs/images/vch-list.en.png" alt="vch list output: three parallel agent tasks, two ok one fail, with vch state details" width="720">
</p>

> **Status: alpha.** The CLI surface is settling but not yet
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

<details>
<summary><strong>“Why not just <code>git worktree</code> + a 5-line shell wrapper?”</strong></summary>

<br/>

Reasonable instinct — that’s how I started. The tree is isolated, but every
`xcodebuild` invocation an agent fires from inside that tree still resolves
to these **global** locations:

- `~/Library/Developer/Xcode/DerivedData/MyApp-<hash>/` (global default)
- `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex/` (global)
- `~/Library/Caches/org.swift.swiftpm/` (global)
- `~/Library/Developer/CoreSimulator/Devices/<UDID>/` (global)

As long as any of those are shared, `xcodebuild` is racy under concurrency.
There are exactly two ways out:

1. **Pass the right flags everywhere.** Remember `-derivedDataPath`,
   `-clonedSourcePackagesDirPath`, and `-resultBundlePath` on every
   `xcodebuild` and `swift test`. Then teach Tuist, Fastlane, every
   custom test script, and any `Package.swift` plugin that shells out to
   do the same. Then teach your *AI agent* not to forget. It will.
2. **Put a PATH shim in front of `xcodebuild`** so those flags are
   guaranteed to be there no matter who or what invokes it.

VibeChard does (2). That’s the whole reason it’s a CLI instead of a
`.zshrc` snippet.

</details>

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
# From inside the task worktree, the task name may be omitted:
#   vch test --scheme MyApp --device "iPhone 16"

# 4. Driving an agent inside the worktree:
vch new fix-toast --exec "claude"     # spawns claude inside the isolated worktree
vch new triage --copy-untracked       # also bring over .env / .vscode / etc.
vch new --adopt-current               # adopt this linked worktree, using its directory name
vch exec fix-toast -- npm run lint    # one-shot command in the worktree

# 5. Inspect & clean up
vch list
vch path add-paywall                  # absolute path of the worktree
vch remove add-paywall                # deletes worktree + branch + sim clone
```

### Agent runbook

If an AI agent is driving the task, point it at the version-matched
runbook:

```sh
vch runbook
```

Inside `vch <name>` / `vch exec`, the child also receives
`VCH_AGENT_RUNBOOK_URL` with the same tag-pinned link. The source copy
lives at **[docs/agent-runbook.md](docs/agent-runbook.md)**.

## Workflow: a series of tasks

VibeChard's sweet spot isn't a single task — it's running **many short
tasks back-to-back** (or in parallel), each in its own worktree, each
landed before the next starts. A typical loop:

```sh
# Plan: A → B → C, each landed before the next starts.

# Task A — implement, test, review.
vch new task-a
cd "$(vch path task-a)"
# ...edit...
vch build --scheme MyApp
vch test  --scheme MyApp --device "iPhone 16"
git commit -am "perf: task A"
vch open task-a                       # review in your IDE

# Once approved, merge from the main worktree:
cd /path/to/main-worktree
git merge --no-ff agent/task-a -m "Merge agent/task-a: <subject>"
vch remove task-a                     # worktree + branch + sim clone gone

# Task B starts from a clean develop, repeats the cycle.
vch new task-b
# ...
```

Each `vch new` gets its own SwiftPM resolve cache, DerivedData, and
module cache under `.vch/`, so two in-flight tasks never block each
other on SPM lock contention or Xcode build cache invalidation. You
can run several `vch test` invocations concurrently from different
shells without a single Core Data store collision or simulator
clobber.

For scripted build/test loops, prefer `vch build` / `vch test` over
raw `vch exec ... xcodebuild ...`; the high-level commands keep
concise summaries, logs, and result bundles wired up:

```sh
vch test task-a --scheme MyApp --device 'iPhone 16' \
  --only-testing MyAppTests/Foo
```

If you need raw tools, prefer the stable `vch state <name> --field
<dotted>` accessor over reading `.vch/state.json` by hand.

## Cookbook

Patterns that aren't a built-in command but come up enough to write
down — branching off mid-WIP work, running a test subset, keeping a
long-running task current, preserving generated artifacts on land,
warm-template fast path, resetting per-task sim state, the Booted
template trap, and pruning merged tasks.

→ See **[docs/cookbook.md](docs/cookbook.md)** for the full set.

## Commands

| Command | What it does |
|---|---|
| `vch new [<name>]` | Create worktree + `agent/<name>` branch, or adopt the current linked worktree (`<name>` may be omitted with `--adopt-current`; `--exec "<cmd>"`, `--copy-untracked`, `--seed-spm-from <task>`, `--cd`). |
| `vch list` | List tasks in the workspace (`--json`, `-v`, `--git-status`). |
| `vch state <name>` | Print `.vch/state.json` for a task (`--json`, `--field <dotted>`). |
| `vch path <name>` | Print the absolute path of a task's worktree. |
| `vch open [<name>]` | Open the worktree in an IDE (`--with xcode`/`code`/`cursor`/…). |
| `vch <name>` | Drop into a shell inside the worktree with isolation active. |
| `vch exec <name> -- <cmd...>` | Run any command inside a task's worktree with isolation active. |
| `vch build [<name>]` | `xcodebuild build` with `-derivedDataPath` / `-clonedSourcePackagesDirPath` injected; `<name>` is optional inside a task worktree (`--scheme`, `--project`, `--workspace`, `--runtime`, `--erase-clone`, `--shutdown-template`, `--verbose`). |
| `vch test [<name>]` | `xcodebuild test` with `-resultBundlePath` injected; `<name>` is optional inside a task worktree; lazy sim clone (`--device`, `--project`, `--workspace`, `--runtime`, `--only-testing`, `--skip-testing`, `--rerun`, `--rerun-failed`, `--erase-clone`, `--shutdown-template`). |
| `vch run [<name>]` | Build, install, launch on the task's sim clone; `<name>` is optional inside a task worktree (`--project`, `--workspace`, `--erase-clone`, `--shutdown-template`, `-- launch-args`). |
| `vch logs <name>` | Print the most recent build/test xcodebuild log (`--test`/`--build`). |
| `vch sim {clone,erase,shutdown,info} <name>` | Manage the per-task simulator clone(s) explicitly; a task can own one clone per platform (e.g. iOS + watchOS) via repeated `vch sim clone --device <name>` ([#99](https://github.com/Maples7/VibeChard/issues/99)). |
| `vch sim warm-template {create,list,remove}` | Manage shared *warm* simulator templates (iOS/watchOS/tvOS/visionOS, [#47](https://github.com/Maples7/VibeChard/issues/47)/[#58](https://github.com/Maples7/VibeChard/issues/58)). |
| `vch land <name>` | Merge `agent/<name>` back into its base and clean up (`--into`, `--no-ff`/`--ff-only`/`--squash`, `--keep`, `--push`/`--push-to`, `--dry-run`). |
| `vch sync <name>` | Fetch the base's upstream and rebase the task branch onto it (`--onto`, `--merge`, `--no-fetch`, `--dry-run`). |
| `vch remove <name>` | Delete vch-created worktree, branch, and sim clone; adopted tasks are unregistered only (`--allow-dirty`, `--force`, `--allow-unmerged`, `--keep-sim`). |
| `vch prune` | List or remove tasks whose branch is fully merged into its base (`--rm`, `--allow-dirty`, `--force`, `--keep-sim`, `--json`). |
| `vch repair` | Re-sync `.vch/state.json` with what `git worktree list` actually shows. |
| `vch clean <name>` | Delete the task's DerivedData / ModuleCache (`--swiftpm`, `--logs`, `--all`, `--dry-run`, `--kill-stuck-tests`). |
| `vch doctor` | Detect orphan sim clones, stale state, corrupt `state.json` (`--clean`, `--bug-report`, `--json`). |
| `vch shellenv` | Emit `vch_cd` / `vch_new` / `vch_clean` shell helpers (bash/zsh). |
| `vch completions install` | Install the shell completion script (`--shell`, `--print`, `--force`). |
| `vch runbook` | Print the version-pinned Agent runbook URL and installed Homebrew doc path hint (`--json`). |
| `vch version` | Print version + toolchain info (`--json` for machine-readable). |

All commands that take a `<name>` complete it from the current
workspace — install completions and hit `<TAB>`. For the full flag
reference see **[docs/commands.md](docs/commands.md)**.

## How isolation works

<p align="center">
  <img src="docs/images/architecture.en.png" alt="Architecture: agents → main repo → worktrees → PATH shim → isolated DerivedData + Sim clones" width="720">
</p>

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

`vch build`, `vch test`, and `vch run` skip the PATH shim and call
`xcodebuild` directly with the same flags, since they know the args at
the call site.

### What `vch exec` / `vch <name>` injects into the child

`vch <name>` (= `vch exec <name> -- $SHELL`) and `vch exec <name> --
<cmd>` give the child a deterministic env layered on top of yours.
The same set drives `vch build` / `vch test` / `vch run`, so any
ad-hoc `xcodebuild` you type inside `vch <name>` behaves identically
to `vch build`. You rarely need a separate "drop me into the task's
env" command — `vch <name>` already is one:

| Variable | Set to |
|---|---|
| `VCH_TASK_NAME` | The task name (e.g. `add-paywall`). Useful for PS1 / window title. |
| `VCH_TASK_ROOT` | Absolute worktree path. |
| `VCH_AGENT_RUNBOOK_URL` | Version-pinned Agent runbook URL for this `vch` binary. |
| `VCH_DERIVED_DATA_PATH` | `<wt>/.agent-build/DerivedData` (read by the shim). |
| `VCH_SPM_CLONE_DIR` | `<wt>/.agent-build/SourcePackages` (read by the shim). |
| `VCH_RESULT_BUNDLE_PATH` | `<wt>/.agent-build/Result.xcresult` (read by the shim). |
| `VCH_RESULT_BUNDLE_DIR` | Parent dir of the result bundle. |
| `CLANG_MODULE_CACHE_PATH` | `<wt>/.agent-build/ModuleCache` (read by clang). |
| `SWIFTPM_CACHE_DIR` | `<wt>/.agent-build/SourcePackages` (read by SwiftPM). |
| `DEVELOPER_DIR` | Host's selected Xcode via `xcode-select -p` — only set if you didn't already export one. |
| `SIMCTL_CHILD_SIMULATOR_UDID` | The task's bound simulator clone — only set if a clone is bound. |
| `PATH` | Prepended with `<wt>/.vch/bin` so `xcodebuild` / `xcrun` / `swift` route through the shim. |

`vch` never clobbers a value you've already exported — set any of
these manually before `vch exec` and your value wins.

## Configuration

None. All per-task state lives at `<worktree>/.vch/state.json`. There
are no `~/.vchrc`, no `.vch.toml`, no global config files. The only
runtime knobs are the `VCH_*` env vars listed above (typically set by
`vch exec` itself; you rarely set them by hand). For build commands,
vch also propagates the host's selected `DEVELOPER_DIR` (resolved via
`xcode-select -p`) into the child process — set the env var manually
to override.

If `vch new` printed a hint about `eval "$(vch shellenv)"`, set
`VCH_NEW_HINT=0` to silence it (or just install the shell helpers).

## What VibeChard is not

- **Not an AI vendor wrapper.** No SDK, no API key, no model
  abstraction. Use whatever agent you like — VibeChard just makes
  parallel sessions safe.
- **Not cross-platform.** Apple-only by design. The whole point is
  depth on the Xcode toolchain.
- **Not a CI orchestrator.** It runs locally, in your terminal,
  against worktrees on your disk. CI matrices are a different
  problem.

## FAQ

<details>
<summary><strong>Does it work with Tuist / Fastlane / xcbeautify?</strong></summary>

<br/>

Yes. The PATH shim catches every `xcodebuild` invocation regardless of
who fires it. Tuist's generated runs, Fastlane's `gym` / `scan`,
`xcbeautify`'s upstream pipe, and any custom test script that ends up in
`xcodebuild` all get the per-task `-derivedDataPath` /
`-clonedSourcePackagesDirPath` / `-resultBundlePath` injected
automatically. No flag plumbing on your side.

</details>

<details>
<summary><strong>CocoaPods / Carthage?</strong></summary>

<br/>

Yes. Their dependency-fetching steps don't go through `xcodebuild`, so
there's nothing to isolate there. Their build steps eventually call
`xcodebuild`, which the shim catches. `Pods/` and `Carthage/`
directories live inside the worktree alongside the source, so they're
isolated by `git worktree` itself.

</details>

<details>
<summary><strong>SwiftPM-only project (no <code>.xcodeproj</code>)?</strong></summary>

<br/>

Works. `swift build` / `swift test` write to the per-worktree `.build/`
directory by default — already isolated for free, no shim flag injection
needed. The shim still wraps `swift` for transparency but doesn't modify
its argv.

</details>

<details>
<summary><strong>What happens to uncommitted changes when I <code>vch remove</code>?</strong></summary>

<br/>

It refuses. `vch remove` aborts on a dirty worktree with a clear
message. Pass `--allow-dirty` to override (deletes uncommitted changes);
pass `--allow-unmerged` (or both flags together) to also allow removing
branches with unmerged commits. There is no silent destructive path.

</details>

<details>
<summary><strong>Do I need an AI agent to use this?</strong></summary>

<br/>

No. Any “I want a parallel sandbox” use case works: try two competing
implementations of the same feature, run a long test suite while you
keep coding on the main worktree, etc. The CLI is agent-agnostic — the
so-called “agent integration” is just `--exec "<your command>"`.

</details>

## Build & test from source

```sh
swift build -c release
./.build/release/vch version
swift test --parallel
```

CI runs the same commands plus a shim smoke probe on every push:
[.github/workflows/ci.yml](.github/workflows/ci.yml).

## License

[Apache-2.0](LICENSE). No CLA. No telemetry. No network calls.
