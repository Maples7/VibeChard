# AGENTS.md — Notes for AI coding agents working on this repo

You are likely Claude / Codex / Copilot / Cursor working inside the **VibeChard**
repository. Read this before making changes.

## What this repo is

A Swift CLI named `vch` that gives Apple developers **isolated parallel
worktrees** so multiple AI agents can build / test / iterate on the same
Apple project without trampling each other's `DerivedData`, `ModuleCache`,
SwiftPM caches, or simulator state.

Locked v1 plan, with rationale and acceptance criteria, lives in agent memory
under `/memories/repo/vibechard-plan.md`. Read it first if you have access.

## Hard rules (do not break)

1. **Apple-only.** Do not add Linux / Windows support, or any "cross-platform
   compatibility" abstractions. The whole point is depth, not breadth.
2. **BYO Agent.** Do not import any AI SDK, do not call any AI HTTP API,
   do not bake in support for a specific agent (Claude/Codex/Copilot/etc.).
   The only agent integration point is the generic `--exec "<cmd>"` flag.
3. **No telemetry.** No network calls. No analytics. Ever.
4. **Two dependencies only:** `swift-argument-parser` and `swift-system`.
   Justify any new dep in the PR description; default answer is "no".
5. **Three targets, fixed:** `VibeChardCore` (library), `vch` (CLI),
   `vch-xcodebuild-shim` (tiny standalone). Do not split further.
6. **The shim must stay minimal.** `Sources/vch-xcodebuild-shim/` cannot
   import `VibeChardCore` or any third-party module. Every xcodebuild call
   from inside an isolated worktree forks this binary; cold start matters.
7. **No config files in v1.** All state goes into per-worktree
   `.vch/state.json`. No `~/.vchrc`, no `.vch.toml`, no env-var-based config
   knobs beyond the documented `VCH_*` set.
8. **Reserved subcommand names:** `new list ls path exec open build test
   logs sim remove rm repair doctor shellenv version help`. `vch new <name>` rejects
   names that match these or start with `-`. `ls` and `rm` are aliases
   for `list` / `remove` respectively (Q-amend post-v0.1.0). `open` opens
   a worktree in an IDE (Xcode / VS Code / Cursor / any `open -a` app);
   added Q-amend post-v0.1.1. `state` shows a task's persisted state and
   `completions` installs shell completions; both added Q-amend post-v0.1.1.
   `logs` prints the firehose log captured during the most recent
   `vch test` run (#9, post-v0.1.2).
9. **Don't touch the user's `~/Library/Developer/`.** Every byte vch writes
   must land inside the worktree's `.vch/` or `.agent-build/`. Do not
   regress this — `ci.yml` smoke-checks the shim's `xcrun -f xcodebuild`
   exec path on every push.

## Architecture map

```
Sources/
├── VibeChardCore/           ← all business logic
├── vch/                     ← thin ArgumentParser shell, calls Core
└── vch-xcodebuild-shim/     ← standalone, no deps, exec replacement
```

`vch` should never contain logic; only argument parsing, output formatting,
and exit-code mapping. Every behavior must be unit-testable from
`VibeChardCoreTests` without touching the disk (use protocol-backed fakes).

## Test layers

| Layer | Where | Runs in CI | Notes |
|---|---|---|---|
| Unit | `Tests/VibeChardCoreTests/` | yes | No IO; protocol fakes only |
| Integration | (later) `Tests/VibeChardCoreTests/Integration/` | yes | Temp git repo + real `/usr/bin/git`; may invoke `xcrun` lazily |
| E2E | manual dogfood against a real Apple project | no | Touches real Xcode + simulators |

## When you change Q-decisions

The grill-me session that produced this design is captured in
`/memories/repo/vibechard-plan.md`. If you find yourself wanting to violate
a rule above, do **not** silently revise it. Surface the trade-off in the
PR description and propose a Q-amendment first.

## Useful local commands

```sh
swift build -c release         # produce .build/release/{vch,vch-xcodebuild-shim}
swift test --parallel
./.build/release/vch version
./.build/release/vch version --json
```

## License

Apache-2.0. Do not change without an explicit user decision.
