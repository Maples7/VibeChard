# Changelog

All notable changes to `vch` are recorded here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/).

The English README is the source of truth; localized READMEs may lag.

## [Unreleased]

### Added
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

## [0.3.0] - 2026-05-08

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

## [0.2.0] - 2026-05-07

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

## [0.1.3] - 2026-05-07

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

## [0.1.2] - 2026-05-06

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

[Unreleased]: https://github.com/Maples7/VibeChard/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Maples7/VibeChard/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Maples7/VibeChard/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/Maples7/VibeChard/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Maples7/VibeChard/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Maples7/VibeChard/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Maples7/VibeChard/releases/tag/v0.1.0
