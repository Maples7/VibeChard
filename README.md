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
- ⬜ M5  — Simulator isolation (lazy clone)
- ⬜ M6  — `vch sim`, `vch doctor`
- ⬜ M7  — Shell completion + Homebrew formula
- ⬜ M8  — `release.yml` → tag v0.1.0 → tap formula auto-bump

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

## License

[Apache-2.0](LICENSE). No CLA. No telemetry. No network calls.
