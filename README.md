# VibeChard

> **Apple-only parallel worktree orchestrator for AI coding agents.**
> Isolates git worktrees, `DerivedData`, the Clang module cache, the SwiftPM
> cache, the result bundle, and even per-task simulator clones — so multiple
> AI coding agents can run `xcodebuild` and `swift test` concurrently without
> tripping `build.db` locks or contaminating each other's state.

> ⚠️ **Status: pre-alpha (v0.0.1).** APIs, CLI surface, and on-disk state
> formats are *not* stable. Wait for v1.0 if you need stability.

## Why

Generic git-worktree managers (Rift, Emdash, Taskpods, Workie, …) stop at
"isolate the source tree." Apple's toolchain has at least seven *more*
shared resources that, when contended by parallel `xcodebuild` runs, cause
non-deterministic failures:

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
that speaks shell. VibeChard is *not* an AI vendor wrapper.

## How it will look (v1, in progress)

```sh
brew install maples7/tap/vch        # available once tap publishes

cd ~/src/MyApp
vch new add-paywall                 # creates ../MyApp-add-paywall on agent/add-paywall
vch add-paywall                     # drops you into a shell with PATH shim active
                                    # → agents/users in there can just run `xcodebuild`
                                    #   and isolation happens transparently

# In another terminal:
vch new fix-toast --exec "claude"   # spawns claude inside an isolated worktree

# Background-style:
vch test  add-paywall --device "iPhone 16"
vch build fix-toast

vch list
vch remove fix-toast
```

## Status

- ✅ M0.5 — PATH-shim PoC validated against a real Apple project (BeanLedger).
  See [scripts/poc/m0_5-shim/](scripts/poc/m0_5-shim/README.md).
- ✅ M0  — SwiftPM scaffolding. `swift build -c release` succeeds;
  `vch version` prints toolchain info.
- ✅ M1  — git + state.json (`vch new` / `list` / `path` / `remove` / `repair`).
  Dirty-worktree guard, `--force` / `--force --force` semantics,
  schema-v1 `.vch/state.json`, table & `--json` output.
- ✅ M2  — Swift port of the bash shim. `vch-xcodebuild-shim` injects
  `-derivedDataPath` / `-clonedSourcePackagesDirPath` / `-resultBundlePath`
  from `VCH_*` env vars when invoked as `xcodebuild`, skips flags the
  user already provided, mkdir -p's the isolation dirs, and `execv`s
  the real binary resolved via `/usr/bin/xcrun -f`. Pass-through for
  `xcrun` / `swift`. 7 end-to-end tests + dogfooded on BeanLedger.
- ✅ M3  — `vch exec <name> -- <cmd...>` runs any command inside a task's
  worktree with `<wt>/.vch/bin` (xcodebuild/xcrun/swift shim symlinks)
  prepended to PATH and isolation env vars set
  (`VCH_DERIVED_DATA_PATH`, `VCH_SPM_CLONE_DIR`, `VCH_RESULT_BUNDLE_PATH`,
  `CLANG_MODULE_CACHE_PATH`, `SWIFTPM_CACHE_DIR`). `vch <name>` is sugar
  for `vch exec <name> -- $SHELL`. `vch shellenv` emits `vch_cd` and
  `vch_clean` helpers (bash/zsh). Foreground only; SIGINT/SIGTERM are
  delivered to the child only. Dogfooded on BeanLedger:
  `xcodebuild -showBuildSettings -json` writes only into
  `.agent-build/DerivedData`, leaving `~/Library/Developer/` untouched.
- ✅ M4  — `vch build <name> [--scheme] [--configuration] [--device] [-- xcodebuild-extras]`
  and `vch test <name>` invoke `xcodebuild` directly (no shim) with
  `-derivedDataPath` / `-clonedSourcePackagesDirPath` injected, plus
  `-resultBundlePath` for `test`. The cwd is the worktree, and
  `CLANG_MODULE_CACHE_PATH` / `SWIFTPM_CACHE_DIR` are set in the env
  so SwiftPM and clang isolate even if the user's `extraArgs` bypass
  some xcodebuild flag. Stale `Result.xcresult` is wiped on each test
  run. After the child exits, vch persists `lastBuild` / `lastTest`
  (and the `scheme` if passed) into `.vch/state.json`. Foreground
  only, signals delivered to the child; vch maps the child's exit
  code through. Dogfooded on BeanLedger:
  `vch build poc-m4 --scheme BeanLedger --device "iPhone 17 Pro"` →
  `** BUILD SUCCEEDED **` with 1.3G DerivedData and 275M SwiftPM in
  the worktree's `.agent-build/`, while `~/Library/Developer/Xcode/DerivedData`
  mtime stays unchanged.
- ✅ M5  — Simulator isolation (lazy clone). `vch build`/`vch test` now
  resolve `--device "iPhone 16"` to a per-task `xcrun simctl clone`
  named `iPhone 16 · vch[<task>]`, persist
  `simulator{cloneUDID, sourceUDID, name}` into `.vch/state.json`,
  call `xcrun simctl bootstatus <udid> -b`, and pass
  `-destination 'platform=iOS Simulator,id=<UDID>'` to xcodebuild
  (id, not name). Subsequent calls reuse the clone silently — even
  without `--device`. Mismatched `--device` against a bound clone
  errors with `simulatorAlreadyBound` instead of silently re-cloning.
  `vch remove` deletes the clone by default; `--keep-sim` preserves
  it. `--no-sim` opts out and falls back to the M4 `name=` path.
  `SIMCTL_CHILD_SIMULATOR_UDID` is set in the build env so child
  `simctl` invocations from tests pin to the clone. Dogfooded on
  BeanLedger: `vch build poc-m5 --scheme BeanLedger --device "iPhone 16"`
  cloned + booted in one shot, `** BUILD SUCCEEDED **`,
  `~/Library/Developer/Xcode/DerivedData` mtime unchanged; reuse
  via `vch test poc-m5 --scheme BeanLedger -- -only-testing:…`
  (no `--device` needed); `vch remove poc-m5 --force` deleted the
  clone cleanly.
- ✅ M6  — `vch sim {clone,erase,shutdown,info} <name>` and
  `vch doctor [--clean] [--json]`. `sim clone` force-creates the
  per-task clone (idempotent — re-running without `--device` is a
  no-op once bound). `sim shutdown` is idempotent at the simctl
  layer (swallows "already shut down"). `sim erase` chains
  shutdown→erase so it works on a Booted clone. `sim info`
  prints the recorded clone + live `simctl` state, including
  `(missing — run vch doctor)` when the device was deleted
  out-of-band. `vch doctor` prunes stale git worktree entries,
  surfaces `state.json` problems, detects orphan `vch[*]`
  simulator clones (e.g. left by `--keep-sim`) and stale state
  bindings (clone gone from simctl), and exits non-zero on any
  finding. `--clean` deletes orphan clones (never auto). `--json`
  emits a machine-readable report. Dogfooded on BeanLedger:
  poc-m6 explicit `vch sim clone` + `sim info` (Shutdown→Booted)
  + `sim shutdown` (idempotent) + `sim erase` (Booted → Shutdown
  + erased); poc-m6b created an orphan via `--keep-sim` →
  `vch doctor` flagged it → `--clean` deleted it; an out-of-band
  `simctl delete` of poc-m6's clone made `vch doctor` report a
  stale binding without false positives.
- ✅ M7  — Shell completion + Homebrew formula. Every command that
  takes a task name (`path`, `remove`, `exec`, `build`, `test`,
  `sim clone`/`erase`/`shutdown`/`info`) now offers TAB-completion
  of real task names via ArgumentParser's `.custom` handler in
  [Sources/vch/TaskNameCompletion.swift](Sources/vch/TaskNameCompletion.swift)
  — invoked through `vch`'s built-in `--generate-completion-script
  {bash,zsh,fish}`, no extra subcommand needed. Outside a git
  workspace the handler returns `[]` so the user's shell falls back
  to default completion silently. `Formula/vch.rb` ships a
  HEAD-installable Homebrew formula (`brew install --HEAD
  maples7/tap/vch`); `url`/`sha256`/`version` are placeholders that
  M8's release workflow will rewrite via
  `mislav/bump-homebrew-formula-action`. The shim lands in
  `libexec/`, **never** in `bin/` (Q10 invariant — the formula
  `test do` block enforces this). Dogfooded on BeanLedger:
  `vch ---completion path -- positional@0 1 0` returned both real
  task names; the same call from `/tmp` returned empty + exit 0.
  `brew style Formula/vch.rb` clean.
- ⬜ M8  — `release.yml` → tag v0.1.0 → tap formula auto-bump.
  Workflow at [.github/workflows/release.yml](.github/workflows/release.yml)
  fires on any `v*` tag push: re-runs the full build/test gauntlet
  on `macos-14`, smoke-checks `vch version` and the shim's
  `xcrun -f xcodebuild` resolution, creates the GitHub Release
  (auto-generated notes; tags containing `-` are flagged
  prerelease), then calls
  `mislav/bump-homebrew-formula-action@v3` to rewrite
  `url` / `version` / `sha256` in `maples7/homebrew-tap`'s
  `vch.rb` (kept at repo root). The bump step is gated on a
  `HOMEBREW_TAP_TOKEN` secret (PAT with `repo` scope on the tap)
  so absence of that secret skips the bump but still ships the
  release. **Pending user action**: push tag `v0.1.0` from
  `master` (`maples7/homebrew-tap` already seeded;
  `HOMEBREW_TAP_TOKEN` already configured). `actionlint` clean.

The full v1 plan (Q1–Q11 decisions, acceptance criteria, parking lot) is
recorded in agent memory under `/memories/repo/vibechard-plan.md` and
mirrored as inline rationale in `AGENTS.md`.

## Build from source

Requirements: macOS 13+, Xcode 15.3+ (Swift 5.10+).

```sh
swift build -c release
./.build/release/vch version
swift test --parallel
```

## Install via Homebrew (HEAD until v0.1.0)

```sh
brew tap maples7/tap            # one-time
brew install --HEAD maples7/tap/vch
```

The formula installs `vch` to `bin/` and `vch-xcodebuild-shim` to
`libexec/` (intentionally **not** in `PATH`). Bash, Zsh, and Fish
completions are generated and installed automatically. Once v0.1.0
is tagged (M8), `brew install maples7/tap/vch` (without `--HEAD`)
will work too.

## License

[Apache-2.0](LICENSE). No CLA. No telemetry. No network calls.
