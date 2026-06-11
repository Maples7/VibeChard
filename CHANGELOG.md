# Changelog

All notable changes to `vch` are recorded here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/).

The English README is the source of truth; localized READMEs may lag.

## 1.2.0 - 2026-06-11

### Added
- `vch test` now prints a periodic `→ still running (Nm elapsed, last
  output Ns ago)` heartbeat to stderr during long, output-quiet
  xcodebuild phases, so a slow run — most acutely a cold watchOS
  clone+boot+build+codesign+validate — stays distinguishable from a
  hang ([#167](https://github.com/Maples7/VibeChard/issues/167)). The
  "last output" figure tails the same byte stream that feeds
  `.vch/last-test.log`, so it doubles as a liveness signal. Cadence is
  controlled by `--progress-interval <seconds>` (default 30; `0`
  disables), and the heartbeat is suppressed under `--verbose` since
  the full firehose is already live.

### Fixed
- `vch build` / `vch test` / `vch run` now fail fast with an
  actionable error in a multi-scheme repo when no scheme can be
  resolved (no `--scheme`, no persisted scheme, and `xcodebuild -list
  -json` reports two or more shared schemes), listing the candidate
  schemes and suggesting `--scheme <name>`
  ([#169](https://github.com/Maples7/VibeChard/issues/169)). Previously
  vch proceeded and leaked xcodebuild's opaque "The flag -scheme … is
  required when specifying -derivedDataPath" — and `vch run
  --existing-sim` booted the shared simulator *before* that failure.
  The check now runs before any simulator clone/boot, so an
  unresolvable scheme produces no side effects. `vch build` / `vch
  test` still honor a `-scheme` passed after `--` (it flows to
  xcodebuild), and single-shared-scheme auto-pick is unchanged.

## 1.1.0 - 2026-06-09

### Added
- `VCH_SHUTDOWN_TEMPLATE_ON_CLONE=1` makes `--shutdown-template` the
  default for `vch build` / `vch test` / `vch run`, so a Booted shared
  warm template no longer requires retyping the flag on every clone
  ([#164](https://github.com/Maples7/VibeChard/issues/164)). The global
  default stays conservative (vch never auto-touches a shared template
  per hard rule #9); the env var is a per-user/per-repo opt-in, and the
  `simulatorTemplateBooted` error now points at it. An explicit
  `--shutdown-template` still wins, and the opt-in is ignored on the
  `--existing-sim` path (no clone happens there).
- `vch run --existing-sim <udid|name>` and `vch build --existing-sim
  <udid|name>` target a pre-existing **shared** simulator instead of a
  per-task clone — the explicit opt-in for "install/build onto the
  simulator I keep open and watch"
  ([#162](https://github.com/Maples7/VibeChard/issues/162)). The device
  is selected by UDID (exact, case-insensitive) or exact name; vch skips
  `simctl clone`, records **no** per-task binding in `state.json` (so
  `vch land` / `vch rm` never reap it), and never erases it.
  `vch run --existing-sim` additionally boots the device and installs +
  launches the app on it, while still reusing the task's isolated
  DerivedData / SwiftPM caches. `--existing-sim` is mutually exclusive
  with `--device`, and rejects `--runtime` / `--erase-clone` /
  `--shutdown-template` (plus `--no-sim` on `vch build`) — those only
  apply to vch's per-task clone.

## 1.0.0 - 2026-06-07

First stable release. The documented CLI surface, the `VCH_*`
environment contract, and the on-disk `.vch/state.json` schema (v1) are
now frozen and covered by [Semantic Versioning](https://semver.org/):
backward-compatible changes ship in minors, breaking changes wait for a
2.0. No code behavior changes versus 0.11.1 — this release is the
stability commitment itself.

### Changed
- Status moved from **alpha** to **stable**. `README` now states the
  SemVer + schema-v1 guarantee, and `CONTRIBUTING` spells out exactly
  what the stable surface covers (commands, flags, `VCH_*` env, and the
  `state.json` v1 format) and what may still change in a minor
  (human-readable wording, log formatting, `.agent-build/` internals).

### Docs
- `README` (and the four localized READMEs) clarify that macOS 13+ /
  Xcode 15.3+ is the **build host** requirement while the produced
  `vch` binary targets macOS 13+, and add an Apple-platform-support
  note: the isolation machinery is platform-agnostic and simulator
  cloning is parameterized for iOS/watchOS/tvOS/visionOS, with
  day-to-day `vch run` validation concentrated on iOS.

### Fixed
- `vch test` no longer prints a misleading `✗ 0 failed, 0 passed … ** TEST
  FAILED **` summary when the build phase fails before any test runs. A
  compile/link failure now renders `✗ build failed — tests not run   ** BUILD
  FAILED **`, so a human scanning the tail can tell a broken build apart from a
  failed test assertion without opening the log (#157).

### Tests
- Added a cross-task isolation guarantee suite that asserts parallel tasks
  never share a `DerivedData` / `ModuleCache` / SwiftPM clone / `xcresult`
  path and that no injected path escapes its worktree into a global Apple
  toolchain location (AGENTS.md rule #9), covering both the default sibling
  layout and adopted linked worktrees.

## 0.11.1 - 2026-05-23

### Fixed
- `vch clean --kill-stuck-tests` and the `vch test` idle-timeout recovery
  hint now include task-scoped `simctl diagnose` children left behind by
  CoreSimulator diagnostic collection after the xcresult has already recorded
  a terminal test result (#154).
- `vch test` now classifies SwiftPM package dependency resolution failures as
  package resolution failures and surfaces the first `xcodebuild: error:` line
  instead of reporting an ambiguous `test status unknown` (#150).
- `vch list --git-status` now shows `MERGED dirty` instead of `MERGED yes`
  when a task branch has no unmerged commits but its worktree still has
  uncommitted changes (#146).
- `vch test` now detects silent test-execution hangs after `xcodebuild` starts
  running tests, terminates the child after `--test-execution-idle-timeout`
  seconds (default: 300), and prints the task, PID, simulator state, log path,
  result bundle path, command, and recovery hints (#151).
- `vch build`, `vch test`, and `vch run` now verify that a bound simulator
  clone is actually `Booted` after `simctl bootstatus -b`; if CoreSimulator
  still reports `Shutdown` or the clone disappears, vch fails before launching
  `xcodebuild` with a recovery hint instead of letting the command wait on an
  unusable destination (#135).

## 0.11.0 - 2026-05-22

### Added
- `vch build`, `vch test`, and `vch run` can now omit `<name>` when
  invoked from inside a vch-managed task worktree, inferring the task
  from `.vch/state.json` (#134).
- Added `--project` / `--workspace` to `vch build`, `vch test`, and
  `vch run` so nested Xcode projects can be selected explicitly
  instead of falling back to the current directory's default
  `xcodebuild` context (#134).

### Changed
- `vch build` / `vch test` now print an actionable simulator
  destination hint when the xcodebuild log indicates no usable
  destination was selected (#134).

### Fixed
- `vch build` / `vch test` now forward SIGHUP/SIGINT/SIGTERM to the active
  `xcodebuild` child instead of letting interrupted wrapper terminals
  leave task-scoped build or test processes behind (#135).
- `vch clean --kill-stuck-tests` now terminates task-scoped `xcodebuild`
  and `SWBBuildService` holders detected under `.agent-build/` / `.vch/`,
  re-scans for remaining holders, and then proceeds with cleanup (#142).
- `vch land` now reports merge conflicts with the base worktree path,
  conflicted files, and explicit resolve / abort / cleanup commands instead
  of only surfacing the raw `git merge` failure (#140).

## 0.10.1 - 2026-05-22

### Changed
- `vch clean --kill-stuck-tests` now also detects and terminates
  task-scoped `xcodebuild build` leftovers, not just `xcodebuild test`
  / `vch test` / XCTestDevices host processes. Recovers the
  `build.db: database is locked` failure that follows an interrupted
  `vch build` whose `xcodebuild build` child outlived its parent
  terminal (#131).

## 0.10.0 - 2026-05-22

### Added
- `vch clean <task>` now detects task-scoped stuck `vch test`,
  `xcodebuild test`, and XCTestDevices host processes before deleting
  build caches, and `--kill-stuck-tests` can send SIGTERM to those
  exact PIDs before cleaning (#127).

## 0.9.2 - 2026-05-16

### Fixed
- Clarified `vch land` wrong-branch diagnostics so resolved `--into`
  failures show the target branch and no longer suggest passing
  `--into` again (#124).

## 0.9.1 - 2026-05-15

### Changed
- Clarified `vch doctor --json` stale-prune reporting: new output uses `worktreePruneRan` for the `git worktree prune` sweep, keeps `prunedStaleEntries` as a deprecated compatibility field, and includes an explicit repair hint for stale simulator bindings.

### Fixed
- Added a recovery hint when `vch build` / `vch test` logs show `SBMainWorkspace Busy` / `Application failed preflight checks`, pointing users to `--erase-clone` or `vch sim erase`.
- Fixed missing-base-device runtime hints so Apple Watch, Apple TV, and Apple Vision Pro templates suggest a matching installed runtime instead of a hardcoded iOS runtime (#119).

## 0.9.0 - 2026-05-14

### Added
- Simulator base device auto-creation (#110): when `vch build --device "iPhone 17" --runtime "iOS 26.5"` is invoked and the device type + runtime are installed but no base device instance exists, vch now automatically creates it via `xcrun simctl create`. This removes the need for users to manually run `simctl create` before their first build — the device type + runtime are sufficient. The created device is not auto-deleted; the user owns its lifecycle and can clean up via `vch doctor --clean` if desired.

### Changed
- Improved error messages when a simulator device cannot be found. The diagnostics now distinguish three failure modes:
  1. Device type not installed → `Device type 'iPhone 17' not installed`
  2. Runtime not installed → `Runtime 'iOS 26.5' not installed`
  3. No base device exists and `--runtime` not specified → suggests adding `--runtime` to trigger auto-creation
  The previous generic "available: none" message is replaced with actionable guidance (#110).

### Fixed
- Pruned stale simulator bindings before simulator selection, so a clone deleted outside vch no longer causes `vch build`, `vch test`, or `vch sim` commands to report false multi-binding ambiguity (#111).
- Made `vch remove` distinguish adopted tasks from vch-created tasks: adopted tasks now report that they were unregistered while keeping the external worktree/branch, and unregistered canonical-looking adopted worktrees no longer reappear in `vch list` or get treated as removable vch-owned worktrees (#112).

## 0.8.1 - 2026-05-14

### Fixed
- Fixed Homebrew release automation so the tap receives the repository's
  full formula template before version and checksum updates, preserving
  the installed Agent runbook file used by `vch runbook` (#108).

## 0.8.0 - 2026-05-14

### Added
- Added an official Agent runbook at `docs/agent-runbook.md`, a
  `vch runbook` discovery command, Homebrew doc installation, and
  `VCH_AGENT_RUNBOOK_URL` inside task environments so agents can find
  version-pinned operating guidance.

## 0.7.1 - 2026-05-14

### Changed
- `vch new --adopt-current` can now omit `<name>`; vch infers it from
  the current linked worktree directory name after confirming the
  directory is a linked worktree and validating the normal task-name
  rules.

### Fixed
- `vch build`, `vch test`, and `vch run` now preserve the selected
  simulator platform when generating `xcodebuild` destinations, so
  watchOS/tvOS/visionOS clone UDIDs are no longer passed as
  `platform=iOS Simulator`. Implicit simulator reuse is also scoped by
  the inferred scheme platform when available, preventing a lone
  watchOS binding from being reused for a later iOS scheme (#102).

## 0.7.0 - 2026-05-14

### Breaking
- `vch sim info --json` output schema changed (#99). Pre-#99 it
  emitted `{"task": "...", "bound": {...} | null }` — a single
  optional record. It now always emits
  `{"task": "...", "bindings": [...] }` — an array of zero or more
  records, with the field renamed from `bound` to `bindings`.
  Scripts and agent automation that read `.bound` will silently see
  no clone on multi-binding tasks (and `null` on unbound tasks);
  migrate to iterating `.bindings`. The pretty-printed (non-`--json`)
  form is unchanged for single-binding tasks and adds
  `--- binding N of M ---` separators when a task owns multiple
  clones.

### Added
- `vch` now supports binding multiple simulator clones to a single
  task — e.g. an iOS clone for the phone target plus a watchOS clone
  for the companion target — instead of capping a task at exactly one
  bound device (#99). `vch build sim --device <name>` and
  `vch sim clone --device <name>` append a new binding when the
  device (and optional `--runtime <version>`) doesn't match any
  existing binding; an exact match still reuses the existing clone
  with no work done. `vch test sim` and `vch run` reuse a single
  binding implicitly, and require `--device` on tasks that own
  multiple bindings.
- `vch sim erase`, `vch sim shutdown`, and `vch sim info` accept new
  `--device` and `--runtime` selectors to pick a specific binding on
  multi-platform tasks. Without a selector, `vch sim info` prints
  every binding (separated by `--- binding N of M ---`) and its JSON
  form now emits `{task, bindings: [...]}` instead of a single record
  (#99).
- New business error `simulatorBindingAmbiguous` (exit code 1) when a
  task has 2+ bindings and the invoked command cannot pick one. The
  error message lists every binding so the agent can re-run with the
  correct `--device` (and `--runtime` when two bindings share a
  device) (#99).

### Changed
- `vch state` now emits one `sim:` line per binding rather than only
  the first record; `vch list` shows `<first> (+N)` in the simulator
  column when a task owns multiple clones (#99).
- `vch rm` and `vch land` (without `--keep-sim`) now reap every
  per-task clone on cleanup. A `simctl delete` failure on one
  binding is reported but no longer blocks the rest from being
  attempted (#99).
- `.vch/state.json` schema (still v1, no version bump): added the
  additive optional field `simulators: [SimulatorRecord]`. The
  legacy single `simulator` field is still written and mirrors the
  first binding, so older `vch` builds keep working against a state
  file produced by this release. Legacy state files with only
  `simulator` are read as a single-binding list (#99).

- `vch new <name> --adopt-current` can register the current linked
  Git worktree as a vch task without creating another worktree, while
  still initializing `.vch/state.json` and the task-local build
  isolation paths for `build` / `test` / `exec` / `run` (#97).
- `vch remove <name>` now unregisters adopted tasks by deleting only
  vch-owned `.vch/` and `.agent-build/` contents, leaving the external
  Git worktree and branch intact (#97).

### Fixed
- `vch land <name>` and `vch sync <name>` no longer hard-code the
  synthetic `agent/<task>` branch name in the merge commit message.
  For adopted tasks (#97), the commit message now uses the branch
  that the user's own worktree is actually on (e.g.
  `Merge feature/codex: subject` instead of
  `Merge agent/codex-task: subject`). Behaviour for non-adopted
  tasks is unchanged because `state.branch` is exactly `agent/<task>`
  in that case.

## 0.6.2 - 2026-05-13

### Changed
- `vch build` and `vch test` summaries now repeat the relevant
  artifact paths at the end of every run: build summaries include the
  full log path, while test summaries include both the full log path
  and the task-local `.xcresult` path (#93). This keeps the useful
  inspection handles visible even when the launch banner has scrolled
  out of an agent transcript.

### Fixed
- Raw `vch exec <task> -- xcodebuild test ...` invocations no longer
  fail on rerun solely because vch's injected task-local
  `.agent-build/Result.xcresult` already exists (#93). The shim now
  clears only the vch-owned result bundle path it injected from
  `VCH_RESULT_BUNDLE_PATH`; user-supplied `-resultBundlePath` values
  are never removed.

### Docs
- README and command docs now steer normal build/test loops toward
  `vch build` / `vch test`, while documenting `vch exec ...
  xcodebuild ...` as a raw escape hatch that preserves isolation but
  does not tee or summarize xcodebuild output (#93).

## 0.6.1 - 2026-05-12

### Fixed
- `vch <build|test|run>` now appends an actionable hint after
  `Error: Unknown option '--<flag>'` whenever the rejected token
  doesn't match an existing first-class vch flag and ArgumentParser
  hasn't already proposed a typo correction (#89). The hint points
  at the `-- <args>` pass-through shape using wording matched to
  the downstream — xcodebuild for `vch build` / `vch test`, the
  launched app for `vch run`. This closes the gap left by 0.6.0's
  #86 fix, which only caught a curated list of known xcodebuild
  flag spellings (`-testPlan`, `-resultBundlePath`, …). The
  existing specific hint still takes priority over the generic one
  on `vch test`. `ArgumentParser`'s own "Did you mean '--scheme'?"
  typo suggestion suppresses the hint so the two diagnostics can't
  stack on the same error.

## 0.6.0 - 2026-05-11

### Added
- `vch test` learns first-class `--only-testing <id>` and
  `--skip-testing <id>` flags (both repeatable, #86). They translate
  to `xcodebuild -only-testing:<id>` / `-skip-testing:<id>` so the
  common "run just one suite / function" workflow no longer needs
  to remember the `--` separator and the single-dash xcodebuild
  spelling. Power users keep full flexibility: anything else still
  goes through `vch test … -- <xcodebuild flags…>`. The new flags
  are mutually exclusive with `--rerun` / `--rerun-failed` for the
  same reason positional `extraArgs` already were.
- When `vch test` rejects an invocation containing an obvious
  xcodebuild flag (e.g. `--testPlan`, `-resultBundlePath`,
  `-parallel-testing-enabled`), vch now emits an actionable hint
  after ArgumentParser's "Unknown option" line — pointing either
  at the new first-class flag (when one exists) or at the
  `vch test … -- -<flag> <value>` pass-through form (#86). The
  hint detector is a pure helper in `VibeChardCore.Logic` so it's
  unit-tested without booting the CLI.

### Changed
- New `VchCLISmokeTests` test target forks the real `vch` binary and
  asserts both directions of the subcommand registry: every name in
  `TaskName.reserved` dispatches to a real subcommand (forward
  direction, the original #82 failure mode), and every subcommand
  surfaced in `vch --help` is in `TaskName.reserved` (reverse
  direction, the symmetric drift that would let a newly-added
  subcommand silently get rewritten by the sugar dispatcher).
  Catches the #82 class of regression at `swift test` time. Mirrors
  the `ShimIntegrationTests` Process-based pattern; AGENTS.md hard
  rule #5 (three Sources targets, fixed) is preserved — only the
  test-target count grows.
- Release workflow gains a per-subcommand `--help` smoke step that
  exercises every tasks-less reserved name against the freshly-built
  release binary, so a botched release artifact can't reach the user
  even if `swift test` is somehow skipped.

### Docs
- AGENTS.md gains Engineering discipline #6 ("One list, one place")
  and #7 ("No logic in `vch/`"). Both formalize the AGENTS.md
  violations that produced the #82 regression: a parallel literal
  copy of `TaskName.reserved` lived inside the `vch` executable
  target, where Swift's `@testable import` restriction (combined
  with hard rule #5 forbidding a third Sources target) made it
  invisible to the unit test suite. The Architecture map's existing
  "vch should never contain logic" paragraph now cross-references
  discipline #7.

## 0.5.1 - 2026-05-11

### Fixed
- `vch prune` and `vch clean` no longer error with the
  self-contradicting `invalid task name '<cmd>': '<cmd>' is a
  reserved subcommand` in v0.5.0 (#82). The root cause was a
  duplicated reserved-name list inside the `vch <name>` sugar
  dispatcher that drifted out of sync with
  `TaskName.reserved` — every newly-added subcommand silently
  routed through the sugar path and got rejected. The dispatcher
  now reads `TaskName.reserved` directly, so there is exactly one
  list. `TaskShortcutDispatcher` also moved from `Sources/vch/` to
  `Sources/VibeChardCore/Logic/` so it can be unit-tested; the new
  test suite asserts every reserved name short-circuits, preventing
  this class of regression from re-appearing.

## 0.5.0 - 2026-05-11

### Added
- `vch prune` — list (and optionally remove) every task whose branch
  is already fully merged into its base (#67). Default is dry-run;
  pass `--rm` to apply. Skips dirty worktrees and worktrees with
  open holders unless `--allow-dirty` / `--force` is set, mirroring
  `vch rm`'s flag vocabulary. Also: `vch list --git-status` gains
  a `MERGED` column (and `git.mergedIntoBase` in `--json`) so the
  same signal is visible without running `prune`.
- `vch test --help` and the README cookbook now ship a worked
  `-only-testing` / `-skip-testing` example (#70). The flag is an
  `xcodebuild` flag (single dash, after a literal `--`), and the
  most common first-time mistake was passing `--only-testing` as
  if it were a vch option.
- `vch build/test/run --erase-clone` — opt-in flag that runs
  `simctl shutdown && simctl erase` on the per-task simulator clone
  before the command (#68). Useful when a test depends on first-launch
  behaviour and the warm template's inherited `UserDefaults` / app
  containers / keychain entries are interfering. Off by default;
  ~10–20 s overhead per invocation, so daily runs stay on the fast
  path. The companion cookbook recipe ("Resetting per-task simulator
  state") explains why this is opt-in: the per-task clone inheriting
  `~/Library` from the warm template is a feature (#47/#58), not a
  bug — `--erase-clone` is the escape hatch for the rare cases where
  it's not.

### Changed
- `vch rm` now classifies held-open processes into *interactive*
  (editors, shells — may have unsaved buffers) and *background*
  (`sourcekit-lsp`, `Code Helper (Plugin)`, `mdworker_shared`, etc.
  — release file handles asynchronously after the editor closes)
  when the worktree is busy (#75). The diagnostic groups them into
  separate sections, drops the misleading "close the editor" hint
  when no interactive holder is involved, and tells the user
  `--force` is safe when `git status` in the worktree is clean and
  only background helpers remain. Holder rows now render the sample
  path relative to the worktree (`./Sources/Foo.swift`) instead of
  repeating the absolute prefix on every line, and a shell `cwd`
  matching the worktree root displays as `(cwd)`. The gate itself
  is unchanged — `--force` is still the explicit override.
- README split into a short mainline and two new English-only
  reference docs. The Cookbook section moved to
  [`docs/cookbook.md`](docs/cookbook.md), and the per-command flag
  prose moved to [`docs/commands.md`](docs/commands.md). The README
  Commands table is now a one-line summary per command with the
  noteworthy flags in parentheses; full flag detail lives in
  `docs/commands.md`. The 5 READMEs went from ~3013 total lines to
  ~1797. `vch land --help` updated to point at the new cookbook URL
  on GitHub instead of "the README cookbook". No CLI behavior
  changes.
- The "build/test status unknown — see full log" trailing line now
  also prints the path to `<wt>/.vch/last-build.log` /
  `last-test.log` (#69). Previously the path was only emitted in
  the launch banner, which had typically scrolled off by the time
  the unknown-status line landed.
- **Breaking**: `vch rm --allow-dirty` no longer overrides held-open
  files (#65). The two concerns — uncommitted changes vs. an
  editor / shell still inside the worktree — are now separate flags:
  - `--allow-dirty` still discards uncommitted changes (and feeds
    `--force` to `git worktree remove`).
  - `--force` is new; it bypasses the held-open-files check (which
    fires when `lsof` reports an open file inside the worktree).
  The `worktreeBusy` error message now points users at `--force`
  instead of `--allow-dirty`. Scripts that previously used
  `--allow-dirty` solely to silence the holders error need to add
  `--force`.

### Docs
- AGENTS.md rule #10 (multi-language README sync) narrowed.
  Substantive README changes still mirror to all 5 locales, but
  extension reference docs under `docs/` (e.g. `docs/cookbook.md`,
  `docs/commands.md`) are now explicitly English-only — single
  source of truth, no translated counterparts. Locale READMEs
  link to the English `docs/...` documents directly.

### Fixed
- `vch build/test/run` now raises a typed, actionable error when
  `simctl clone` refuses to clone a Booted warm template, instead
  of bubbling up the raw `Unable to clone device in current state:
  Booted` stderr blob (#66). The new message names the offending
  template, prints its UDID for copy-paste into `xcrun simctl
  shutdown`, and points at the matching opt-in flag
  `--shutdown-template`. The flag is off by default per hard rule
  #9 — the warm template is shared across tasks, so vch never
  shuts it down without an explicit user opt-in. Typical trigger:
  the user launched the warm template from `Simulator.app` (or an
  Xcode UI test session) and forgot to shut it down; the next
  `vch build` in a fresh task explodes mid-clone.
- `vch test --rerun-failed` now repairs short-form swift-testing
  identifiers before feeding them back to `xcodebuild` (#64).
  Under some Xcode 16 swift-testing setups, xcresulttool emits
  `Suite/Case()` (two segments) instead of the documented
  `Target/Suite/Case()` (three). Passing the short form back to
  `xcodebuild -only-testing:` made xcodebuild parse the first
  segment as the test-target name and abort with
  `Tests in the target "<Suite>" can't be run because "<Suite>"
  isn't a member of the specified test plan or scheme.` `vch` now
  prepends `<targetName>/` (taken from the same `testFailures`
  entry) when the first segment doesn't already match the target
  name, so the rerun command works without manual editing.

## 0.4.0 - 2026-05-09

### Added
- `vch land --keep-sim` — keep the per-task simulator clone even
  when auto-`rm` succeeded (#61). Symmetric with
  `vch rm --keep-sim`; useful for inspecting simulator state
  immediately after a merge.
- `vch sim warm-template` now supports **watchOS, tvOS, and visionOS**
  in addition to iOS (#58). The `--runtime` argument accepts the
  full set of forms — `iOS 26.4` / `watchOS 11.5` / `tvOS 18.0` /
  `visionOS 2.5` (dotted), `iOS-26-4` / `watchOS-11-5` / `xrOS-2-5`
  (dashed), or the raw CoreSimulator identifier
  (`com.apple.CoreSimulator.SimRuntime.iOS-26-4`,
  `…SimRuntime.xrOS-2-5`, etc.). Warm templates and per-task clones
  for non-iOS devices are dropped into the same simctl pool with
  the same `vch-warm[<device>:<runtime>]` name pattern, so they
  show up alongside iOS templates in `vch sim warm-template list`
  and `vch doctor`. Existing iOS warm templates created on
  v0.3.x continue to work after upgrading — both the on-disk simctl
  names and `state.json`'s `runtimeIdentifier` parse identically.
  visionOS uses Apple's internal `xrOS` slug in CoreSimulator runtime
  identifiers but the human-facing name is `visionOS`; the parser
  accepts both prefixes (`xrOS-2-5` and `visionOS-2-5` both resolve
  to the same runtime), and the warm-template name always emits the
  human form (`vch-warm[Apple Vision Pro:visionOS 2.5]`).
  - **Empirical savings, watchOS** (Apple Watch Series 10 (46mm) +
    watchOS 11.5, N=3 median): cold path **31.0 s** → warm path
    **23.3 s**, savings **7.7 s (24.9 %)**. Lower than the iOS
    win (21.4 s / 69.4 %, see #47) — watchOS first-boot does less
    cache priming work — but well above the 2 s noise floor, so
    the optimisation ships across all four supported platforms.
    tvOS and visionOS are likely in the same ballpark; the SPIKE
    methodology lives in PR #58 and can be re-run by users with
    those runtimes installed.
- `vch sim warm-template {create,list,remove}` — shared warm
  simulator templates (#47). A warm template is a simulator device
  that vch keeps in shutdown state with first-boot caches already
  primed (created → booted via `simctl bootstatus -b` → shutdown).
  Subsequent per-task `simctl clone` operations inherit those
  caches, so the cloned device boots in seconds instead of tens of
  seconds. SPIKE measured the cold path (`simctl create` from an
  Apple template + first boot, iPhone 16 + iOS 26.4, N=5 median)
  at 30.75 s vs. the warm path (clone + boot, same conditions) at
  9.41 s — savings of 21.35 s absolute (69.4 %) per task on the
  first sim spin-up. `vch test --device "iPhone 16" --runtime "iOS 26.4"`
  automatically picks the matching warm template when one exists,
  falling back to the unfiltered Apple-template scan otherwise.
  Lifetime is **decoupled** from any task: warm templates are
  created only by `warm-template create` and destroyed only by
  `warm-template remove`. `vch doctor` lists them but never
  auto-cleans them — the user owns their lifecycle. Storage uses
  zero on-disk metadata; the simctl device name pattern
  `vch-warm[<device>:<runtime>]` is the single source of truth
  (matches AGENTS.md rule #7 — no `~/.vch*`, no global config
  files). New `sourceKind` field on `state.simulator` records
  whether a clone came off a warm template (`warm-template`) or
  an Apple template (`apple-template`); legacy state.json files
  still decode (the field is optional). Queryable via
  `vch state <task> --field simulator.sourceKind`. New error variants:
  `warmTemplateAlreadyExists` (business exit code) and
  `invalidRuntime` (usage exit code). New `vch doctor` output
  section + `warmTemplates[]` JSON field. `warm-templates.json`
  added to the `vch doctor --bug-report` tarball.
- `vch new --seed-spm-from <task>` COW-clones a sibling vch task's
  SwiftPM bare-mirror cache into the new task at create time so
  the first build can skip the dependency network fetch (#55).
  Implementation uses APFS `clonefile(2)` directly, with full
  copy-on-write semantics: the new task gets a private view that
  splits from the source on first write. Only the
  `<src>/.agent-build/SwiftPM/repositories/` subdir is seeded —
  `checkouts/` is rebuilt locally on first build because its
  embedded `.git` config has stale absolute back-pointers that
  aren't safe to share. Validation (source task exists, source
  has a populated SwiftPM cache) runs *before* the new worktree
  is created, so a typo never leaves a half-initialised task
  behind. Two new business-error variants:
  `seedSourceTaskNotFound` and `seedSourceHasNoSwiftPMCache`.
  Source task may be removed at any time after seeding without
  affecting the new task. Requires APFS; non-APFS volumes will
  surface the underlying `clonefile(2)` error.
- `vch land --push` and `vch land --push-to <remote>` push the
  resolved `--into` branch to a remote after the merge succeeds
  (#49). `--push` resolves the remote via `branch.<into>.remote`
  config, falling back to `origin` when no upstream is configured.
  `--push-to=<remote>` overrides and takes precedence over `--push`.
  Without either flag `vch land` never contacts a remote — the
  merge stays purely local. If the post-merge push fails (network,
  non-fast-forward, missing perms), the merge is **not** rolled
  back; the failure is surfaced as a stderr warning that includes
  the exact `git push <remote> <branch>` command to retry.
- `vch test --rerun` replays the last `vch test <name>` invocation
  verbatim — the prior `xcodebuild` extra args (anything passed
  after `--`) are now persisted into `.vch/state.json` on every
  test run and read back on `--rerun` (#46). Errors out with
  `testNoPriorRun` if the task has never run `vch test`.
- `vch test --rerun-failed` re-runs only the tests that failed in
  the most recent run by walking the recorded xcresult bundle for
  failed test identifiers and translating each one into
  `-only-testing:<id>`. Works for both XCTest and swift-testing
  (the identifiers come from xcresult, which is unified). Other
  prior args (`-parallel-testing-enabled NO`, `-test-iterations 3`,
  …) are preserved; only `-only-testing:` / `-skip-testing:`
  selectors are stripped before the failure-derived ones are
  appended. Errors out with `testNoPriorFailures` if the last run
  was clean (#46).
- `TaskState.TestRecord.extraArgs: [String]?` records the extra
  args passed to the most recent `vch test` invocation. `nil`
  on legacy state.json files written before this field existed;
  `[]` when the run had no extras (#46).
- `vch sync <name>` brings a task branch back up to date with its
  recorded base after fetching the upstream. Default strategy is
  `git rebase`; pass `--merge` for `git merge --no-ff` (use when
  `agent/<name>` was manually pushed somewhere a coworker reads
  from). `--onto <ref>` overrides the base, accepting anything
  `git rev-parse` can resolve. `--no-fetch` skips the network call
  for offline use. `--allow-dirty` is a pass-through that lets git
  decide whether the operation can proceed; default behaviour is
  to refuse on uncommitted changes. `--dry-run` prints the planned
  strategy with ahead/behind counts and writes nothing. All git
  work runs inside the task worktree, so the user's main worktree
  is never disturbed. When `state.baseBranch` is a local branch
  (the `vch new` default — `git fetch` does not advance local
  refs), `vch sync` automatically rebases onto the
  `<remote>/<branch>` form so the new commits are actually picked
  up; pass `--onto` or `--no-fetch` to opt out. Reserved-name list
  grows to include `sync`. Closes the `<name>`-shaped half of #25;
  `--all` deferred to a follow-up.

### Changed
- `SimRuntimeVersion` carries a `platform: Platform` discriminator
  (`iOS` / `watchOS` / `tvOS` / `visionOS`) instead of being iOS-only
  (#58). Existing call-sites using the positional
  `SimRuntimeVersion(major: 26, minor: 4)` constructor keep
  compiling — the platform parameter defaults to `.iOS` to preserve
  source compatibility. `iOSRuntimeIdentifier` is renamed to
  `runtimeIdentifier` to stop lying when called on non-iOS values.
  `dottedLabel` now emits the platform name (e.g. `watchOS 11.5`)
  instead of the hardcoded `iOS X.Y` prefix. The `--runtime` parser
  is now case-insensitive on the platform prefix (`ios 26.4` and
  `iOS 26.4` resolve identically).
- `vch test --runtime` / `vch run --runtime` / `vch build --runtime`
  / `vch sim warm-template create --runtime` / `vch sim warm-template
  remove --runtime` help text now lists watchOS / tvOS / visionOS
  examples alongside the iOS ones.
- The `simulatorTemplateNotFound` "available: …" hint emitted by
  `pickNewestTemplate` now uses the platform-aware
  `dottedLabel` so non-iOS pickers see correctly-prefixed runtime
  labels in the diagnostic. Was previously hardcoded to `iOS X.Y`
  even when the available runtimes were watchOS or tvOS.
- `vch build` now mirrors `vch test`'s concise-summary path
  instead of streaming the full xcodebuild firehose to stdout
  (#48). The default output is a single trailing line
  (`✓ build succeeded in 12.4s   (3 warnings)   ** BUILD SUCCEEDED **`
  on success, an error list followed by
  `✗ build failed in 8.1s   (2 errors, 5 warnings)   ** BUILD FAILED **`
  on failure). The full firehose is always tee'd to
  `<wt>/.vch/last-build.log` and recoverable via the new
  `vch logs <name> --build`. Pass `--verbose` to mirror
  xcodebuild's full output to stdout the way `vch build` used
  to. The build log is bundled into `vch doctor --bug-report`
  on the same terms as `last-test.log` (256 KiB cap, `$HOME`
  scrubbed).
- `vch logs <name>` accepts `--build` alongside `--test` (mutually
  exclusive). Default remains `--test` when neither is passed (#48).
- `state.json` gains an optional `lastSync` record (no schema
  bump; additive optional field, follows the `lastBuild` /
  `lastTest` / `lastExec` precedent). `vch state` and
  `vch state <field>` surface the new dotted keys
  `lastSync.finishedAt`, `lastSync.baseSHA`, `lastSync.baseLabel`,
  `lastSync.strategy`, `lastSync.appliedCommits`, and
  `lastSync.durationSeconds`.

### Removed
- `vch remove --force` / `-f` (the deprecated alias introduced in
  0.3.0). Use `--allow-dirty` for a dirty worktree and
  `--allow-unmerged` for an unmerged branch (or both together).
  Pre-1.0 minors are allowed to break per CONTRIBUTING.md.

### Fixed
- `vch land` now deletes the per-task simulator clone after a
  successful merge + auto-`rm`, matching `vch rm`'s long-standing
  behaviour (#61). Previously the simulator-cleanup logic lived
  only in the `vch rm` CLI handler, so every successful `vch land`
  silently left an orphan device behind in `simctl list` (≈ 3 GB
  per task) that only `vch doctor --clean` could reap. The new
  cleanup runs in `LandService` so both code paths share the same
  contract:
  - skipped under `--keep` (task is still alive),
  - skipped under the new `--keep-sim` flag (symmetric with
    `vch rm --keep-sim`),
  - skipped on `--dry-run`,
  - skipped if auto-`rm` itself failed (worktree still on disk →
    user may retry),
  - non-fatal if `simctl delete` itself fails: the merge is never
    rolled back; `vch land` prints a warning and points the user
    at `vch doctor --clean`.
- `vch test` now reports the real passed/failed count for
  swift-testing targets (#45). The previous summary line printed
  `✓ 0 passed in ?` for any target that uses `@Suite` / `@Test` /
  `#expect` because the streaming xcodebuild parser only
  recognized the XCTest stdout protocol. We now read the
  `.xcresult` bundle vch already writes via `-resultBundlePath`
  through `xcrun xcresulttool get test-results summary` and
  prefer that count when the streaming parser came back empty.
  Streaming parser stays in place as a fallback for the case
  where xcodebuild aborted before producing a bundle (e.g. a
  compile failure). Failure detail (suite, test name, message,
  and `testIdentifierString`) is also surfaced from xcresult so
  the `✗ Suite/testCase` block renders for swift-testing
  failures too. Pure XCTest output is unchanged — the streaming
  parser still owns the per-suite rollup lines and the `file:line`
  failure references it can extract from XCTest stdout.

### Documentation
- `vch land --help` and the README now spell out that `vch land`
  only carries **committed** content into the destination branch:
  uncommitted changes, untracked files, and `.gitignore`d artifacts
  in the task worktree are not part of the merge and are deleted
  along with the worktree on the auto-`vch rm` step. New cookbook
  recipe "Preserving generated artifacts when landing" shows the
  `--keep` → manual copy → `vch rm` recovery flow. No behaviour
  change.

## 0.3.0 - 2026-05-08

### Added
- `vch list --git-status` enriches the table with `AHEAD/BEHIND`,
  `DIRTY`, and `LAST COMMIT` columns. The base for ahead/behind is
  the recorded `baseBranch` (recorded by `vch new` since 0.2.0),
  falling back to the recorded short SHA when no branch was active.
  Each git query is best-effort — a flaky repo degrades the affected
  field to `-` instead of breaking the whole listing. Off the cheap
  default path (one extra `git rev-list` + `git status` per
  worktree). JSON output gains an optional `git` block when the flag
  is set; the default JSON shape is unchanged. Closes #24.
- `vch clean <name>` removes the task's `DerivedData` and
  `ModuleCache` (default), with `--swiftpm` for the SwiftPM clone
  dir, `--logs` for `.vch/last-test.log`, and `--all` for everything.
  Refuses to delete when any process still has a file open inside
  `.agent-build/` or `.vch/` (e.g. an Xcode that's actively
  indexing); `--dry-run` lists what would be removed. Reserved-name
  list grows to include `clean`. Closes #26.
- `vch doctor --bug-report` bundles a redacted local diagnostics
  tarball: every task's `state.json` and (capped) `last-test.log`,
  the porcelain worktree list, and `sw_vers` / `xcode-select -p` /
  `xcrun -f xcodebuild` / `swift --version` output. `$HOME` paths
  are scrubbed in every textual entry. No network calls — the user
  is the only one deciding what to share. Default output:
  `./vch-bug-report-<UTC-stamp>.tgz`; override with `--out`. Plan
  Q10.
- `vch new --cd` opts into a machine-readable contract: stdout
  prints **only** the absolute worktree path (no extra log lines,
  no progress), all status / hints route to stderr. Lets fish /
  nushell / any non-bash-zsh shell wrap with `cd "$(vch new --cd
  foo)"` without parsing. Mutually exclusive with `--exec` (exit 2
  on conflict — `--exec` execve's into the agent before vch would
  ever print). The `vch_new` shellenv helper now uses `--cd` itself,
  pinning the contract via test as well as documentation. Closes
  #32 (B half; A shipped in 0.3.0 above).
- README cookbook section ("Branching off mid-WIP work") documents
  the `git stash --include-untracked` + `vch new --base agent/<src>`
  + `git stash apply` recipe for forking a task off another task's
  uncommitted state. Mirrored across 5 locales. Replaces the
  `vch fork` proposal in #27 (closed as won't-fix; the atomic
  staged + unstaged + untracked + selectively-ignored transfer has
  no native git primitive and the manual recipe is stable enough).
- README "What `vch exec` / `vch <name>` injects into the child"
  section enumerates the deterministic env vars set in the child
  process (`VCH_TASK_*`, `VCH_DERIVED_DATA_PATH`,
  `CLANG_MODULE_CACHE_PATH`, `SWIFTPM_CACHE_DIR`, `DEVELOPER_DIR`,
  `SIMCTL_CHILD_SIMULATOR_UDID`, `PATH` shim). Closes #31 — the
  `vch shell` proposal becomes redundant once users know `vch
  <name>` already drops them into the task's full env.

### Changed
- `vch build`, `vch test`, `vch run`, and `vch exec` now propagate
  the host's selected `DEVELOPER_DIR` (resolved via `xcode-select
  -p` and cached) into the child process, mirroring xcodebuild's own
  behaviour. Prevents stale-Xcode mismatches when an agent is run
  outside a regular shell. The user's existing `DEVELOPER_DIR`
  override always wins. Closes #31 (the env-injection half;
  `vch shell` itself stays parked, see README).
- `vch new` prints a one-line hint about `eval "$(vch shellenv)"`
  when stdout is a TTY and the shell helper sentinel
  (`VCH_SHELL_HELPER`) is not set. Suppress with `VCH_NEW_HINT=0`,
  or with the new `--cd` flag (machine-readable mode). `vch
  shellenv` exports the sentinel so the hint vanishes once helpers
  are installed. Closes #32 (A half).
- **Per-task simulator clone naming** changed from
  `<original> · vch[<task>]` to `<original>-vch-<task>` — plain
  ASCII suffix that is friendlier for shells, JSON, and Apple's
  Simulator picker. `vch doctor` recognizes both the new hyphen
  suffix and the legacy middle-dot bracket form when scanning for
  orphans, so existing clones keep working without migration (UDID,
  not display name, is the source of truth). New `vch build` /
  `vch test` / `vch run` clones use the new shape. Closes #29.

### Deprecated
- `vch remove --force` (once) and `--force --force` (twice) are now
  deprecated aliases for `--allow-dirty` and `--allow-dirty
  --allow-unmerged` respectively. Both still work and now emit a
  one-line stderr warning suggesting the named flags. Scheduled for
  removal in 0.4.0 (pre-1.0 minors are allowed to break per
  CONTRIBUTING.md). Error messages for dirty worktrees and unmerged
  branches point at the named flags instead of the old `--force`
  recipe.
  Closes #30.

## 0.2.0 - 2026-05-07

### Added
- `vch run <name>` builds the task's app, then installs and launches
  it on the task's bound simulator clone in a single command. The
  scheme auto-detection and `--runtime` rules match `vch build`;
  `PRODUCT_BUNDLE_IDENTIFIER` is auto-resolved post-build via
  `xcodebuild -showBuildSettings -json` so there is no `--bundle-id`
  flag. Everything after `--` is forwarded verbatim to `simctl
  launch` (e.g. `vch run alpha -- -UsePreviewSampleData`). Boots the
  clone and best-effort opens `Simulator.app` if it is not already
  running. Reserved-name list grows to include `run`. Closes #18.
- `vch land <name>` merges a task branch back into its recorded base
  branch and removes the task worktree in one command. Default
  strategy is `--no-ff`; `--ff-only` and `--squash` are also
  available. Pre-flight refuses to merge when (a) the main worktree's
  HEAD is not on `--into`, (b) the task branch is not strictly ahead
  of `--into` (no-op merge), or (c) the main worktree has uncommitted
  changes whose paths intersect the task branch's diff (pass
  `--allow-dirty` to override; non-overlapping dirty state is fine).
  The default merge commit message is `Merge agent/<name>: <last
  non-merge subject>`; `--message` overrides. `--keep` skips the
  auto-rm. `--dry-run` prints the planned merge without modifying
  any branches. Reserved-name list grows to include `land`. Closes
  #7.
- `vch new` now records the main worktree's branch as
  `state.baseBranch` so `vch land` can default `--into` correctly.
  Optional field — older `state.json` files (without `baseBranch`)
  load fine; `vch land` falls back to the main worktree's current
  branch in that case.
- `vch test` now produces a concise summary by default — at most a
  few dozen lines for a passing 100-test run, with each failing test
  expanded inline as `✗ Suite/testName` plus its file:line and
  assertion message. The full xcodebuild firehose is always tee'd to
  `<wt>/.vch/last-test.log` and accessible via `vch logs <name>`.
  Pass `--verbose` to mirror the firehose to the terminal in real
  time (the previous default behavior). Output stays parseable by
  simple `grep -E '✓ \d+ passed'` / `grep '✗ '` patterns. Status
  is honest: vch never invents a `✓` / `✗` when xcodebuild
  bailed out before emitting `** TEST SUCCEEDED **` / `** TEST
  FAILED **` (e.g. compile failure). XCTest only in this revision;
  Swift Testing's emoji-prefixed format flows through the log file
  but is not yet summarized. Closes #9.
- `vch logs <name>` (with `--test`, currently the only flavor) prints
  the most recent `vch test` log so users don't have to remember the
  on-disk path. Reserved-name list grows to include `logs`. Part of
  #9.
- `vch state <name> --field <dotted>` prints a single scalar from
  `state.json` for use in scripts (e.g.
  `udid=$(vch state foo --field simulator.udid)`). Mirrors
  `git config --get` semantics: exit 0 when set, exit 1 when the
  field is known but unset, exit 2 when the field name is
  unrecognized. Stable surface — the dotted-path registry lives
  in `TaskStateField.known`. Closes #8.
- `vch build <name> --runtime <id>` and `vch test <name> --runtime
  <id>` pin the simulator runtime when multiple iOS runtimes share
  the same device template name. Accepts three forms:
  `iOS 26.4`, `iOS-26-4`, or the full
  `com.apple.CoreSimulator.SimRuntime.iOS-26-4` identifier. The
  resolved runtime is persisted on the per-task simulator clone;
  reusing a clone with a different `--runtime` is rejected with
  a clear error. On a runtime miss, vch lists every iOS runtime
  the device template is currently installed against so the user
  can copy-paste the right value. Closes #11.
- `vch build` / `vch test` auto-pick the scheme when the worktree
  exposes exactly one shared scheme (via `xcodebuild -list -json`).
  Resolution order: `--scheme` flag → previously recorded scheme
  in `state.json` → single-shared-scheme detection → xcodebuild's
  built-in default. The chosen scheme is logged once so it isn't
  silent. No new config files (AGENTS.md §7). Closes #6 (read-only
  subset).

### Fixed
- `vch test --device "iPhone 16"` invoked twice in a row no longer
  raises `simulatorAlreadyBound` even though the binding *is* the
  same `iPhone 16` clone. Previously vch compared the user's
  requested template name against the *clone display name*
  (`iPhone 16 · vch[<task>]`), so the second call always
  mismatched. The clone's source template name is now persisted
  separately on `SimulatorRecord.templateName`, with a fall-through
  suffix-strip for state files written by vch ≤ v0.1.x. Closes #4.
- `xcodebuild` destinations now pin `arch=arm64` (or `arch=x86_64`
  on Intel hosts), silencing the `Using the first of multiple
  matching destinations` warning that surfaced in iOS 26 SDK builds
  where every device template advertises both architectures.
  Closes #5.
- `vch remove` (without `--force`) refuses to delete a worktree
  that still has live processes inside it. Holders are detected
  via `lsof -F pcn +D <wt>` and listed with pid, command, and a
  sample held path so the user knows what to close first.
  `vch remove --force` keeps the historical bypass. Closes #10.

### Changed
- `vch build` / `vch test` log lines now include the resolved
  iOS runtime version when a simulator clone is involved, e.g.
  `→ booting simulator 'iPhone 16 · vch[alpha]', runtime: iOS 26.4`.
  Surfaces silent runtime drift for free. Part of #11.

### Tests
- New `LandPlannerTests` (16) cover every branch of the `vch land`
  pre-flight decision tree: explicit `--into`, recorded-base-branch
  fallback, current-main fallback, no-op detection, overlap refusal,
  `--allow-dirty` bypass, default vs user-supplied message, dry-run
  + `--keep` flag plumbing, and sorted overlap path output. New
  `LandServiceIntegrationTests` (15) exercise the same scenarios
  end-to-end against a real `/usr/bin/git` + temp repo: clean merge,
  `--keep`, `--dry-run`, `--squash`, `--ff-only` (success +
  divergent-history refusal), custom message, no-op refusal,
  overlapping-dirty refusal, non-overlapping dirty allowed,
  `--allow-dirty` bypass, missing branch fallback, wrong main branch,
  explicit `--into`, and `state.baseBranch` persistence by
  `vch new`. `PorcelainParserTests` gained 9 cases for the new
  `parseStatusPorcelainZ` parser (modified, untracked, rename + copy
  two-token entries, paths with spaces, defensive guards).
  `TaskStateTests` gained 2 cases pinning `state.baseBranch`
  backward-compatible decoding (legacy state.json without the field
  loads with `baseBranch == nil`) and round-trip with the field set.
  `TaskNameTests` extended for the new `land` reservation. Total:
  229 → 271.
- New `TestOutputSummarizerTests` (11) covers the XCTest log parser:
  passing run, failure with file:line + assertion message, failure
  with `path:line:column` form, crash without preceding error line,
  multi-suite mixed outcomes, render shape, and graceful degradation
  to `unknown` status on compile-only output. `WorkspaceTests` and
  `TaskNameTests` extended for the new `lastTestLogPath` and the
  `logs` reserved-name addition. Total: 218 → 229+.
- New `LsofParserTests` (7), `TaskStateFieldTests` (8), and
  `SchemeResolverTests` (9). `SimulatorServiceTests` gained 4 cases
  for the `--runtime` filter and reuse-time mismatch error.
  `BuildPlannerTests` / `BuildServiceTests` updated for the
  `arch=arm64` field that destinations now pin. Total: 188 → 218.

### Docs
- README "Workflow: a series of tasks" section across all five
  locales (`en` / `zh-CN` / `zh-TW` / `ja` / `ko`), walking through
  the full `vch new` → edit → `build` / `test` → review →
  `git merge --no-ff agent/<task>` → `vch rm` cycle, the
  parallel-isolation guarantee, and a script-friendly example using
  the new `--field` accessor. Also documents `--runtime` and the
  scheme auto-pick rules in the command tables. Closes #12.
- `CONTRIBUTING.md` documents the branching model (GitHub flow, no
  `develop` / `release/*` / `hotfix/*`), Conventional Commits scope
  list, PR rules, the test layering against `Tests/`, the
  pre-1.0 versioning policy, and the release flow as the single
  documented exception to "no direct pushes to master". Read by
  humans and AI agents alike (the latter still defer to
  `AGENTS.md` rules first).
- `CONTRIBUTING.md` follow-ups aligning the doc with the actual
  branch-protection setup: release commits now also go through a
  PR (`chore/release-x.y.z` branch) instead of being a "documented
  exception" to the no-direct-push rule; only the tag push remains
  outside protection. Calls out that branch protection is what
  *enforces* the no-direct-push rule, that feature branches are
  auto-deleted on merge by the repo setting, and adds a typical
  `gh pr create --fill` / `gh pr checks --watch` / `gh pr merge
  --squash --delete-branch` loop in the local-commands section.
- README hero banner (`docs/images/hero.<locale>.png`, 5 locales)
  rendered at 1920×800 and embedded at the top of every README so
  the "what does this actually look like?" question gets answered
  in the first screen instead of below the fold. The banner contrasts
  a red "Without vch" panel (`Build database is locked`,
  `ModuleCache.noindex` collisions, etc.) against a green "With vch"
  panel showing colorized `vch list` output. Renderer in
  `scripts/render-docs-images/build.js` extended with a `THERO`
  copy table and a `HERO_SIZE` viewport (1920×800) alongside the
  existing square 1080×1440 one, so each `npm run build` now
  produces 15 PNGs (5 locales × 3 image kinds) instead of 10.
- A 25-second VHS-recorded `docs/images/demo.gif` placed right
  after the `brew install` block in all 5 READMEs. Walks
  through `vch new` × 2 → `vch list` → `vch state` → `vch exec
  swift --version` → `vch remove` × 2 → final empty `vch list`,
  paced (75 ms typing speed, 1.8–3.5 s sleeps) so the multi-row
  tables and the colorized `vch state` output have time to read.
  Re-recordable via `scripts/vhs-demo/demo.tape` (Tokyo Night
  theme, 1200×700 viewport). Sibling `scripts/vhs-demo/README.md`
  documents the prereqs (`brew install vhs`,
  `VCH_DEMO_PROJECT=/path/to/your/Apple/project`).
- New "Why not just `git worktree` + a 5-line shell wrapper?"
  `<details>` block inside the existing "Why a CLI just for this?"
  section across all 5 locales. Lists the four `~/Library/...`
  global locations that vanilla `git worktree` still leaves shared
  (`DerivedData`, `Caches/org.swift.swiftpm`,
  `Caches/org.llvm.clang/ModuleCache`, `CoreSimulator/Devices`) and
  frames vch as the PATH-shim answer. Pre-empts the most common
  reader instinct on first read.
- New FAQ section before "Build & test from source" in all 5
  locales answering five high-frequency compatibility questions:
  Tuist / Fastlane / xcbeautify, CocoaPods / Carthage,
  SwiftPM-only projects (no `.xcodeproj`), what `vch remove`
  does to uncommitted changes (refuses by default, `--force` once
  for dirty trees, twice for unmerged branches), and using vch
  without an AI agent.

### Fixed
- Localized README typography across `README.zh-CN.md`,
  `README.zh-TW.md`, `README.ja.md`, `README.ko.md`: merged
  paragraph line breaks where the previous line ended with a
  CJK-side character (Chinese / Japanese / Hangul ideograph or
  CJK punctuation `、，。「」（）`, em-dash `——`) and the next
  line began with another CJK character. GFM joins consecutive
  lines in the same paragraph with a literal U+0020 space, which
  inside a CJK run renders as a visible gap mid-sentence (e.g.
  zh-CN FAQ Q5 used to show "跑 长测试套件" with the space). The
  fix is purely whitespace: 92 + 13 + 2 such pairs were merged
  in-place across the four files; English-CJK and code-CJK
  boundaries (where a space *is* the convention) were left alone,
  matching the existing copy style.

## 0.1.3 - 2026-05-07

### Added
- ANSI colorization for `vch list` and `vch state` so the CLI matches
  the marketing screenshots in `docs/images/`. Headers render gray;
  `NAME` is bright blue + bold; `BRANCH` is bright magenta; `SIM` is
  bright yellow (dim when `-`); `BUILD ok/fail` is bold green / red;
  `BASE` / `CREATED` placeholders are dim. `vch state` additionally
  colors the last build / test status words and the `exit N` token
  in last exec (green when N==0, red otherwise). Policy lives in
  `VibeChardCore/ANSI.swift`: `NO_COLOR` (no-color.org) always wins;
  `FORCE_COLOR` / `CLICOLOR_FORCE` opt in even without a TTY (handy
  for `| less -R`); otherwise colorize iff stdout is a TTY. Column
  widths are computed on the *uncolored* text and padding is applied
  before wrapping in ANSI so alignment stays exact regardless of
  escape-code byte length. Styles use 8/16-color bright variants so
  they compose with whatever theme the user's terminal already has.

### Fixed
- `vch list -v` and `vch state` now format `CREATED` and last-action
  timestamps in the user's local time zone with explicit offset
  (e.g. `2026-05-07T10:22:17+08:00`) instead of UTC `Z` notation —
  still a valid ISO 8601 string, but no more mental conversion every
  time you read the table. JSON output (`vch list --json`,
  `vch state --json`) intentionally keeps UTC via `JSONEncoder`'s
  `.iso8601` strategy: machine consumers shouldn't drift with the
  user's locale.

### Docs
- Status badges (release, CI, license, platform, Swift) added to the
  top of all five READMEs.
- Localized `docs/images/vch-list.<locale>.png` and
  `docs/images/architecture.<locale>.png` screenshots for en / ja /
  ko / zh-CN / zh-TW, embedded into each README.
- Renderer that produced the screenshots committed under
  `scripts/render-docs-images/` (see its `README.md`) so future
  contributors can regenerate the assets deterministically.

### Pristine output paths (unchanged)
- `--json`, `vch path`, `vch shellenv`, `vch completions install
  --print` emit zero ANSI bytes regardless of TTY / `FORCE_COLOR`.
  Scripts that consume them (`$(vch path foo)`,
  `eval "$(vch shellenv)"`, etc.) keep working.

### Tests
- 14 new `ANSITests` lock down the policy matrix (`NO_COLOR` vs
  `FORCE_COLOR=0/1/false/empty` vs `CLICOLOR_FORCE` vs
  default-follows-TTY) and the exact SGR byte sequences emitted per
  style. Full suite: 185/185 passing.

## 0.1.2 - 2026-05-06

### Added
- `vch state <name>` — pretty-print a task's `.vch/state.json` (name,
  branch, path, base, scheme, sim ID, last build / test / exec
  timestamps). `--json` emits the raw file contents. Distinguishes
  `taskNotFound` (worktree absent) from `stateFileMissing` (worktree
  present, state file gone — pointing the user at `vch repair`).
- `vch list -v` / `--verbose` — adds `BASE` and `PATH` columns to the
  table view. Pairs with the existing `--json` output for piping.
- `vch completions install [--shell <s>] [--print] [--force]` —
  installs the shell completion script under the standard XDG /
  user location for `zsh` (`~/.zsh/completions/_vch`), `bash`
  (`~/.local/share/bash-completion/completions/vch`), or `fish`
  (`~/.config/fish/completions/vch.fish`). Auto-detects the active
  shell from `$SHELL`. `--print` previews the install path + script
  + post-install hint without writing; `--force` overwrites an
  existing file.
- `vch_new` shell helper in `vch shellenv` — runs `vch new` and `cd`s
  into the new worktree in one step. Detects `--exec` / `--exec=*`
  in `$@` and short-circuits to `command vch new "$@"` (since execve
  replaces the shell, no cd is possible after handoff). Always uses
  `command vch` to avoid recursion through user aliases.
- `vch new <name> --copy-untracked` — also copies every git-untracked,
  non-ignored file (e.g. `.env`, `.vscode/settings.json`,
  `scripts/local.sh`) from the main worktree into the new worktree,
  preserving permissions and symlinks. Files matched by `.gitignore`
  / `.git/info/exclude` (e.g. `node_modules/`, build outputs) are
  skipped, as are vch's own `.vch/` and `.agent-build/` scratch dirs.
  Combine with `--exec` to ship a fully-configured worktree to an
  agent in one shot: `vch new fix --copy-untracked --exec "claude"`.
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
- Reserved subcommand list now includes `open`, `state`, and
  `completions` (previously: `new list ls path exec build test sim
  remove rm repair doctor shellenv version help`). `vch new state`
  / `vch new completions` are rejected at parse time.

### Tests
- 4 new `TaskService` tests for `stateForTask` (taskNotFound when
  worktree absent; stateFileMissing when worktree present but state
  file gone; stateFileCorrupt carries the real path; happy path
  returns parsed `TaskState`).
- 13 new `CompletionsInstallerTests` covering `CompletionShell.detect`
  (zsh / bash / fish, case insensitive, nil for missing/empty/unknown)
  and `CompletionsInstaller.plan` (path + post-install hint per
  shell, trailing-slash + root-home edge cases).
- 3 new / updated `ShellEnvScript` tests asserting all three helpers
  (`vch_cd`, `vch_new`, `vch_clean`) are emitted, that `vch_new` short-
  circuits when `--exec` is present, and that it uses `command vch`
  to bypass user aliases.
- 5 new `TaskService` tests for `--copy-untracked` (off by default;
  copies preserve relative layout; skips `.vch/` + `.agent-build/`;
  rejects `/abs` and `../escape` paths; no-op on empty listing).
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

## 0.1.1 - 2026-05-06

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

## 0.1.0 - 2026-05-06

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
