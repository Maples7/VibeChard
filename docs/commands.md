# VibeChard Commands Reference

Full prose reference for every `vch` subcommand. The
[Commands cheatsheet in the README](../README.md#commands) is the
one-line summary; this is where the flag detail lives. Run
`vch <command> --help` for the live, version-pinned flag list.

> **Note on languages.** This document is English-only on purpose —
> see [AGENTS.md rule #10](../AGENTS.md). The 5-locale READMEs link
> to the relevant section here when they need to reference a flag.

## Contents

- [Creating and inspecting tasks](#creating-and-inspecting-tasks)
  - [`vch new`](#vch-new)
  - [`vch list`](#vch-list)
  - [`vch state`](#vch-state)
  - [`vch path`](#vch-path)
  - [`vch open`](#vch-open)
- [Working inside a task](#working-inside-a-task)
  - [`vch <name>`](#vch-name)
  - [`vch exec`](#vch-exec)
- [Building, testing, running](#building-testing-running)
  - [`vch build`](#vch-build)
  - [`vch test`](#vch-test)
  - [`vch run`](#vch-run)
  - [`vch logs`](#vch-logs)
- [Simulator management](#simulator-management)
  - [`vch sim`](#vch-sim)
  - [`vch sim warm-template`](#vch-sim-warm-template)
- [Finishing and cleanup](#finishing-and-cleanup)
  - [`vch land`](#vch-land)
  - [`vch sync`](#vch-sync)
  - [`vch remove`](#vch-remove)
  - [`vch prune`](#vch-prune)
  - [`vch repair`](#vch-repair)
  - [`vch clean`](#vch-clean)
  - [`vch doctor`](#vch-doctor)
- [Meta commands](#meta-commands)
  - [`vch shellenv`](#vch-shellenv)
  - [`vch completions`](#vch-completions)
  - [`vch runbook`](#vch-runbook)
  - [`vch version`](#vch-version)

All commands that take a `<name>` complete it from the current
workspace — install completions and hit `<TAB>`.

## Creating and inspecting tasks

### `vch new`

```text
vch new [<name>] [--exec "<cmd>" | --cd] [--copy-untracked] [--seed-spm-from <task>] [--adopt-current] [--base <ref>]
```

Without `--adopt-current`, create a worktree at `../<repo>-<name>` on
branch `agent/<name>`.
When `--adopt-current` is used, `<name>` may be omitted; vch infers it
from the current linked worktree directory name and validates it with
the normal task-name rules.

- `--exec "<cmd>"` runs a command inside the new worktree (e.g. an
  AI agent like `claude` or `codex`).
- `--copy-untracked` also copies git-untracked, non-ignored files
  (e.g. `.env`, `.vscode/settings.json`) from the main worktree.
- `--seed-spm-from <task>` COW-clones a sibling vch task's SwiftPM
  bare-mirror cache so this task's first build skips the dependency
  network fetch (APFS only; source task must already have built once).
- `--adopt-current` registers the current linked Git worktree as the
  task instead of creating another `git worktree`. Use this when an
  agent tool already created the worktree; vch still writes
  `.vch/state.json` and uses task-local build isolation.
- `--cd` opts into the machine-readable contract: stdout prints
  **only** the absolute worktree path, all status/hints go to
  stderr — for fish/nushell wrappers like `cd "$(vch new --cd foo)"`.
  Mutually exclusive with `--exec`.
- `--base <ref>` overrides the base branch (default: the branch the
  main worktree was on at the time of `vch new`).

### `vch list`

List all tasks in the current workspace.

- `--json` for machine output.
- `-v` / `--verbose` adds `BASE` + `PATH` columns.
- `--git-status` adds `AHEAD/BEHIND` + `DIRTY` + `MERGED` +
  `LAST COMMIT` columns (one extra `git rev-list` + `git status` per
  worktree). `MERGED` is `yes` only when the branch is merged and the
  worktree is clean; a merged branch with uncommitted changes reports
  `dirty`.

### `vch state`

```text
vch state <name> [--json | --field <dotted>]
```

Pretty-print `.vch/state.json` for a task.

- `--json` for the raw file contents.
- `--field <dotted>` prints just one scalar (e.g. `simulator.udid`)
  — designed for `$(vch state foo --field simulator.udid)` in scripts.

### `vch path`

Print the absolute path of a task's worktree.

### `vch open`

```text
vch open [<name>] [--with <ide>]
```

Open the worktree in an IDE.

- Auto-detects `*.xcworkspace` / `*.xcodeproj` / `Package.swift`
  (Xcode for project files, VS Code otherwise).
- `--with` accepts `xcode`, `code` / `vscode`, `cursor`, or any app
  name (passed to `open -a`).
- Override default with `VCH_OPEN_DEFAULT`.
- With no `<name>`, uses the worktree containing `$PWD`.

## Working inside a task

### `vch <name>`

Sugar for `vch exec <name> -- $SHELL` — drops you into a shell with
isolation env vars + `.vch/bin` PATH shim active.

### `vch exec`

```text
vch exec <name> -- <cmd...>
```

Run any command inside a task's worktree with isolation active. See
the [How isolation works](../README.md#how-isolation-works) section
of the README for the env vars vch injects.

`vch exec` is the raw escape hatch. When the command resolves to the
shimmed `xcodebuild`, vch still injects isolation flags and clears a
stale vch-owned result bundle before exec, but it does not tee,
summarize, or retain logs. Prefer `vch build` / `vch test` for normal
build/test loops.

## Building, testing, running

### `vch build`

```text
vch build [<name>] [flags] [-- xcodebuild-extras]
```

`xcodebuild build` against the task's worktree, with
`-derivedDataPath` / `-clonedSourcePackagesDirPath` injected.

- `<name>` may be omitted when the current directory is inside a
  vch-managed task worktree; vch infers it from `.vch/state.json`.
- `--scheme` is optional when the project has exactly one shared
  scheme (auto-detected via `xcodebuild -list -json`); once recorded,
  vch reuses it on subsequent calls. In a repo with two or more shared
  schemes and no recorded scheme, vch fails fast with the candidate
  list and asks for `--scheme <name>` instead of leaking xcodebuild's
  `-scheme`/`-derivedDataPath` flag conflict
  ([#169](https://github.com/Maples7/VibeChard/issues/169)); a
  `-scheme` passed after `--` is still honored.
- `--project <path>` / `--workspace <path>` select an explicit
  xcodebuild container (relative to the task worktree unless absolute).
  They are mutually exclusive and are useful for nested Xcode projects
  in repositories that also have a root `Package.swift`.
- `--runtime 'iOS 26.4'` (or `'watchOS 11.5'`, `'tvOS 18.0'`,
  `'visionOS 2.5'`) pins the simulator runtime.
- If no base device exists and `--runtime` is omitted, vch suggests
  the newest installed runtime matching the requested device platform
  (for example, watchOS for Apple Watch templates).
- `--erase-clone` runs `simctl shutdown && simctl erase` on the
  per-task clone first (off by default; see
  [Resetting per-task simulator state](cookbook.md#resetting-per-task-simulator-state)).
- `--shutdown-template` shuts the warm template down and retries when
  `simctl clone` refuses because the template is Booted (off by
  default; see
  [When `simctl clone` says the template is "Booted"](cookbook.md#when-simctl-clone-says-the-template-is-booted)).
  Set `VCH_SHUTDOWN_TEMPLATE_ON_CLONE=1` to make it the default for
  this shell/repo without changing the conservative global default.
- `--existing-sim <udid|name>` builds the **simulator** variant against
  a pre-existing shared simulator (selected by UDID — exact,
  case-insensitive — or exact device name) instead of a per-task clone:
  vch skips `simctl clone`, writes no per-task binding, and targets that
  device's platform via `-destination id=<udid>`. Mutually exclusive
  with `--device`; `--no-sim` / `--runtime` / `--erase-clone` /
  `--shutdown-template` are rejected. See
  [Installing onto an existing shared simulator](cookbook.md#installing-onto-an-existing-shared-simulator).
- By default prints only a concise summary (`✓ build succeeded in 12.4s   (3 warnings)`) plus the full log path; `--verbose` mirrors xcodebuild's full output.
- The full firehose is always tee'd to `<wt>/.vch/last-build.log`.

### `vch test`

```text
vch test [<name>] [flags] [-- xcodebuild-extras]
```

`xcodebuild test` against the task's worktree, with
`-resultBundlePath` injected; lazy-clones a simulator on first
`--device` and reuses it after.

- Same task-name inference, scheme auto-pick, `--project` /
  `--workspace`, and `--runtime` rules as `vch build`.
- `--only-testing <id>` / `--skip-testing <id>` are first-class
  ([#86](https://github.com/Maples7/VibeChard/issues/86)): repeatable
  flags that translate to `xcodebuild -only-testing:<id>` /
  `-skip-testing:<id>`. The pass-through after `--` is still there
  for everything else (e.g. `-- -testPlan MyPlan`); see
  [Running a subset of tests](cookbook.md#running-a-subset-of-tests).
- `--erase-clone` resets the per-task clone before running (useful
  when a test depends on first-launch defaults; see
  [Resetting per-task simulator state](cookbook.md#resetting-per-task-simulator-state)).
- `--shutdown-template` shuts a Booted warm template down and retries
  the clone (see
  [When `simctl clone` says the template is "Booted"](cookbook.md#when-simctl-clone-says-the-template-is-booted)).
  `VCH_SHUTDOWN_TEMPLATE_ON_CLONE=1` makes it the default for this
  shell/repo.
- By default prints only a concise summary (one line per suite,
  failing tests expanded with file:line and assertion message) plus
  the full log and result bundle paths; `--verbose` mirrors
  xcodebuild's full output to the terminal.
- `--test-execution-idle-timeout <seconds>` defaults to 300. Once
  xcodebuild prints `Testing started` or a test suite starts, this
  many seconds with no further xcodebuild output is treated as a
  stalled test execution: vch terminates the child, exits 124, and
  prints the task, PID, simulator state, log path, result bundle path,
  command, and recovery hints. Use `0` to disable the watchdog.
- `--progress-interval <seconds>` defaults to 30. During long,
  output-quiet phases (most acutely a cold watchOS clone+boot+build)
  vch prints a `→ still running (Nm elapsed, last output Ns ago)`
  heartbeat to stderr on this cadence, so a slow run stays
  distinguishable from a hang — the "last output" figure tails the same
  stream as `.vch/last-test.log` and doubles as a liveness signal. Use
  `0` to disable; suppressed under `--verbose` (the firehose is already
  live).
- The full firehose is always tee'd to `<wt>/.vch/last-test.log`.
- Counts come from the xcresult bundle so swift-testing
  (`@Suite` / `@Test` / `#expect`) targets are reported correctly.
- `--rerun` replays the prior invocation verbatim;
  `--rerun-failed` re-runs only the tests that failed last time
  (uses the recorded xcresult). See
  [Running a subset of tests](cookbook.md#running-a-subset-of-tests).

### `vch run`

```text
vch run [<name>] [flags] [-- launch-args]
```

Build, install, and launch the task's app on its bound simulator
clone.

- Same task-name inference, scheme auto-pick, `--project` /
  `--workspace`, and `--runtime` rules as `vch build`.
- `--erase-clone` resets the per-task clone before installing (off
  by default).
- `--shutdown-template` shuts a Booted warm template down and retries
  the clone (off by default; see
  [When `simctl clone` says the template is "Booted"](cookbook.md#when-simctl-clone-says-the-template-is-booted)).
- `--existing-sim <udid|name>` installs + launches on a pre-existing
  shared simulator (selected by UDID — exact, case-insensitive — or
  exact device name) instead of a per-task clone. vch skips
  `simctl clone`, records no per-task binding (so `vch land` / `vch rm`
  never reap it), boots the device, and never erases it. Mutually
  exclusive with `--device`; `--runtime` / `--erase-clone` /
  `--shutdown-template` are rejected. See
  [Installing onto an existing shared simulator](cookbook.md#installing-onto-an-existing-shared-simulator).
- `PRODUCT_BUNDLE_IDENTIFIER` is auto-resolved via
  `xcodebuild -showBuildSettings -json`.
- Everything after `--` is forwarded verbatim to `simctl launch` —
  e.g. `vch run alpha -- -UsePreviewSampleData`.
- Boots the clone and opens `Simulator.app` if needed.

### `vch logs`

```text
vch logs <name> [--test | --build]
```

Print the full xcodebuild log from the task's most recent run.
Defaults to `--test`; pass `--build` for the build firehose. Logs are
overwritten on each run.

## Simulator management

### `vch sim`

```text
vch sim clone    <name> [--device <name>] [--runtime <version>]
                        [--erase] [--shutdown-template]
vch sim erase    <name> [--device <name>] [--runtime <version>]
vch sim shutdown <name> [--device <name>] [--runtime <version>]
vch sim info     <name> [--device <name>] [--runtime <version>] [--json]
```

Manage the per-task simulator clone(s) explicitly. A single task can
own **multiple** clones — typically one per platform (e.g. an iOS
clone for the phone target plus a watchOS clone for its companion,
[#99](https://github.com/Maples7/VibeChard/issues/99)).

- `clone` with a `--device` that doesn't match any existing binding
  appends a new clone; with a matching `--device` (and optional
  `--runtime`) it reuses the existing one.
- If the requested base device has not been created yet and
  `--runtime` is omitted, the error suggests an installed runtime for
  that device family instead of assuming iOS.
- `erase` / `shutdown` need `--device` (and optionally `--runtime`
  to disambiguate two bindings of the same device) when the task
  owns 2+ clones. With a single binding `--device` is optional.
- `info` defaults to printing **every** binding (separated by
  `--- binding N of M ---`); `--device`/`--runtime` filter to one.
  The JSON form emits `{task, bindings: [...]}`.

When a command can't pick a single binding it fails with the
`simulatorBindingAmbiguous` business error (exit code 1) and lists
every binding so you can re-run with the right selector.

### `vch sim warm-template`

```text
vch sim warm-template {create, list, remove}
```

Manage shared *warm* simulator templates ([#47](https://github.com/Maples7/VibeChard/issues/47),
[#58](https://github.com/Maples7/VibeChard/issues/58)). A warm
template is a primed-then-shutdown simulator that subsequent per-task
`vch test` clones inherit caches from, cutting first-sim-spin-up
(iOS measured: ~30 s → ~9 s; watchOS: ~31 s → ~23 s). Works for
iOS, watchOS, tvOS, and visionOS.

- `create <device> --runtime "iOS 26.4"` (or `"watchOS 11.5"`,
  `"tvOS 18.0"`, `"visionOS 2.5"`) creates one.
- `list [--json]` shows what exists.
- `remove <device> --runtime "..."` deletes one.

**Lifetime is decoupled from any task** — `vch remove` and
`vch doctor --clean` never touch warm templates; you create and
delete them yourself. `vch test --device "<device>" --runtime "..."`
automatically picks the matching warm template when one exists. See
[Skipping the first-boot delay with warm simulator templates](cookbook.md#skipping-the-first-boot-delay-with-warm-simulator-templates).

## Finishing and cleanup

### `vch land`

```text
vch land <name> [--into <branch>] [--no-ff | --ff-only | --squash]
                [--message MSG] [--keep] [--keep-sim] [--allow-dirty]
                [--dry-run] [--push | --push-to <remote>]
```

Merge `agent/<name>` back into its base branch (the branch the main
worktree was on at `vch new`, recorded in `state.json`) and remove
the worktree.

- Default strategy `--no-ff`.
- Default message `Merge agent/<name>: <last non-merge subject>`.
- Refuses on a no-op merge, on a wrong main branch, and when the main
  worktree has uncommitted changes whose paths intersect the task
  branch's diff (use `--allow-dirty` to override).
- `--keep` skips the auto-rm; `--dry-run` prints the plan without
  modifying anything.
- After a successful auto-rm, vch also deletes the per-task simulator
  clone (mirroring `vch rm`'s default); pass `--keep-sim` to retain
  it.
- `--push` pushes the resolved `--into` branch to its tracked remote
  (`branch.<into>.remote`, falling back to `origin`); `--push-to <remote>`
  overrides with an explicit remote. Without either flag `vch land`
  never contacts a remote. If the post-merge push fails the merge is
  **not** rolled back — the failure is surfaced as a stderr warning.
- Only **committed** content is carried over — uncommitted changes,
  untracked files, and `.gitignore`d artifacts in the worktree are
  lost when the worktree is removed (use `--keep` + manual copy; see
  [Preserving generated artifacts when landing](cookbook.md#preserving-generated-artifacts-when-landing)).

### `vch sync`

```text
vch sync <name> [--onto <ref>] [--rebase | --merge] [--no-fetch]
                [--allow-dirty] [--dry-run] [-q]
```

Fetch the recorded base branch's upstream and rebase `agent/<name>`
onto it.

- `--merge` switches to `git merge --no-ff` (use only when the task
  branch has been pushed somewhere a coworker reads from).
- `--onto <ref>` overrides the base.
- `--no-fetch` skips the network call.
- `--allow-dirty` defers the dirty-worktree check to git itself.
- `--dry-run` prints ahead/behind counts and the planned strategy
  without writing.
- All git work runs inside the task worktree, so the main worktree
  is never touched. Records `lastSync` on success. See
  [Keeping a long-running task current](cookbook.md#keeping-a-long-running-task-current).

### `vch remove`

```text
vch remove <name> [--allow-dirty] [--force] [--allow-unmerged] [--keep-sim]
```

For vch-created tasks, delete the worktree, branch, and (by default)
simulator clone. For `--adopt-current` tasks, unregister vch by
removing only `.vch/` and `.agent-build/`; the external Git worktree
and branch remain intact. Adopted-task removal prints
`unregistered <name>` instead of `removed <name>` to make that
ownership boundary explicit; after unregistering, the task no longer
appears in `vch list`. Use `git worktree remove` and `git branch -d`
manually if you also want to delete the external worktree and branch.

- `--allow-dirty` permits uncommitted changes.
- `--force` overrides the held-open-files check (e.g. an editor still
  open inside the worktree,
  [#65](https://github.com/Maples7/VibeChard/issues/65)).
- `--allow-unmerged` force-deletes a branch that isn't fully merged.
- `--keep-sim` retains the per-task simulator clone.

### `vch prune`

```text
vch prune [--rm] [--allow-dirty] [--force] [--keep-sim] [--json]
```

List (default) or remove (`--rm`) every task whose branch is already
fully merged into its base.

- Skips dirty worktrees (`--allow-dirty` overrides) and worktrees
  with open holders (`--force` overrides).
- `--keep-sim` retains the per-task simulator clone (default: delete).
- One pruned task per row; the rest are reported on stderr with the
  reason they were skipped. See
  [Cleaning up tasks whose branches have already merged](cookbook.md#cleaning-up-tasks-whose-branches-have-already-merged).

### `vch repair`

Re-sync `.vch/state.json` with what `git worktree list` actually
shows.

### `vch clean`

```text
vch clean <name> [--swiftpm] [--logs] [--all] [--dry-run] [--kill-stuck-tests] [--json]
```

Delete the task's `DerivedData` + `ModuleCache` (default).

- Add `--swiftpm` to also drop the SwiftPM clone dir.
- Add `--logs` to drop `.vch/last-test.log`.
- `--all` for everything.
- Refuses if any process still has a file open inside `.agent-build/`
  or `.vch/` (e.g. an Xcode that's actively indexing).
- Also refuses when it detects a task-scoped stuck `vch test`,
  `xcodebuild` (build or test), `simctl diagnose`, or XCTestDevices
  app host process. Re-run with `--kill-stuck-tests` to send SIGTERM
  to those exact task-scoped PIDs before cleaning. The same flag can
  also terminate task-scoped `xcodebuild` / `SWBBuildService`
  holders found under `.agent-build/` or `.vch/`. After SIGTERM, vch
  re-scans before deleting and still refuses cleanup if any managed
  holder remains.
  This is the recovery path when an interrupted `vch build` leaves an
  orphan `xcodebuild build` holding `build.db`, or when `xcodebuild test`
  finishes but CoreSimulator diagnostic collection keeps the task alive
  after the xcresult already has a terminal result (#131, #142, #154).
- `--dry-run` lists what would be removed.

### `vch doctor`

```text
vch doctor [--clean] [--json]
vch doctor --bug-report [--out <path>] [--json]
```

Detect orphan simulator clones, stale state bindings, and corrupt
`state.json`s. Exits non-zero on any finding.

`vch doctor` runs `git worktree prune` as part of the sweep. JSON
output reports this as `worktreePruneRan`; the legacy
`prunedStaleEntries` field is retained for compatibility but no
longer claims a mutation occurred. Stale simulator bindings are
reported only: doctor does not edit task state for missing clone
UDIDs. Recreate the binding with `vch sim clone <task> --device ...`,
or run the next `vch build` / `vch test` with `--device` so vch can
prune and rebind during simulator selection.

`--bug-report` bundles a redacted local diagnostics tarball: every
task's `state.json` + `last-test.log`, the porcelain worktree list,
and `sw_vers` / `xcode-select -p` / `xcrun -f xcodebuild` /
`swift --version` output. `$HOME` paths are scrubbed. No network.
Default output: `./vch-bug-report-<UTC-stamp>.tgz`.

## Meta commands

### `vch shellenv`

Emit `vch_cd` / `vch_new` / `vch_clean` shell helpers (bash/zsh).

### `vch completions`

```text
vch completions install [--shell <s>] [--print] [--force]
```

Install the completion script for `zsh` / `bash` / `fish`
(auto-detected from `$SHELL`). `--print` previews; `--force`
overwrites.

### `vch runbook`

```text
vch runbook [--json]
```

Print the Agent runbook reference for this exact `vch` binary. The
human output includes the tag-pinned GitHub URL and the Homebrew doc
path hint; `--json` emits `{vch, url, local, homebrew}` for agent
scripts.

### `vch version`

Print version + toolchain info (`--json` for machine-readable).
