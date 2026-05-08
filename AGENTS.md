# AGENTS.md — Notes for AI coding agents working on this repo

You are likely Claude / Codex / Copilot / Cursor working inside the **VibeChard**
repository. Read this before making changes.

## What this repo is

A Swift CLI named `vch` that gives Apple developers **isolated parallel
worktrees** so multiple AI agents can build / test / iterate on the same
Apple project without trampling each other's `DerivedData`, `ModuleCache`,
SwiftPM caches, or simulator state.

Locked v1 plan, with rationale and acceptance criteria, lives in agent memory
under `/memories/repo/vibechard-plan.md`. Read it for the *original Q-decision
rationale* if you have access — but treat it as a historical artifact, not a
current-state spec. The plan itself carries a STALE WARNING; per Engineering
discipline #1 below, when the plan and the source tree disagree, **the source
tree wins.**

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
   run logs sim remove rm repair doctor shellenv version help`. `vch new <name>` rejects
   names that match these or start with `-`. `ls` and `rm` are aliases
   for `list` / `remove` respectively (Q-amend post-v0.1.0). `open` opens
   a worktree in an IDE (Xcode / VS Code / Cursor / any `open -a` app);
   added Q-amend post-v0.1.1. `state` shows a task's persisted state and
   `completions` installs shell completions; both added Q-amend post-v0.1.1.
   `logs` prints the firehose log captured during the most recent
   `vch test` run (#9, post-v0.1.2). `land` merges a task branch back
   into its recorded base and removes the worktree (#7, post-v0.1.2).
   `run` builds, installs, and launches the task's app on its bound
   simulator clone (#18, post-v0.1.2).
9. **Don't touch the user's `~/Library/Developer/`.** Every byte vch writes
   must land inside the worktree's `.vch/` or `.agent-build/`. Do not
   regress this — `ci.yml` smoke-checks the shim's `xcrun -f xcodebuild`
   exec path on every push.
10. **Multi-language README sync.** Substantive changes to `README.md`
    (features, commands, install steps, rules) must be mirrored to
    `README.ja.md`, `README.ko.md`, `README.zh-CN.md`, `README.zh-TW.md`
    in the same PR. If you cannot translate confidently, add
    `<!-- TODO: sync with README.md -->` at the top of the affected file
    rather than letting it silently drift. Pure typo / link / formatting
    fixes are exempt.

## Engineering discipline

These are workflow expectations, not project policies. They live here
because past sessions repeatedly rediscovered them the hard way.

1. **Source code is the source of truth.** When evaluating whether a
   change is feasible, necessary, or correct, **read the code**.
   Plan documents (`/memories/repo/vibechard-plan.md`, milestone
   result notes, even your own previous CHANGELOG entries) drift
   between sessions. Treat them as hypotheses to verify, not facts
   to act on. If the plan and the code disagree, the code wins.
2. **Add tests when behaviour changes.** Any meaningful logic change
   to `VibeChardCore` or `vch` deserves a unit test in
   `Tests/VibeChardCoreTests/` — usually one new test case in an
   existing file, or one small new file. Bug fixes get a regression
   test that would have failed pre-fix. Pure refactors and pure
   moves don't need new tests, but the existing suite must stay
   green and you must say so in the PR.
3. **Update CHANGELOG.md whenever the change is user-visible.**
   New flags, behaviour changes, deprecations, removals, and bug
   fixes go under `[Unreleased]`. Pure docs and internal refactors
   are exempt. Every CHANGELOG line must be defensible from the
   diff — if a bullet has no matching code, you shipped a lie.
4. **Keep README in sync with the source.** Command-table rows,
   flag descriptions, examples, and architecture claims must reflect
   the current code. The 5-locale sync rule (#10 above) applies to
   any substantive update — but the rule above it is that README
   must not lie about what the binary does.

## Architecture map

```
Sources/
├── VibeChardCore/           ← all business logic
│   ├── Domain/              ← pure value types, errors, exit codes
│   ├── System/              ← IO abstractions (protocol + Disk* impl)
│   ├── Logic/               ← pure transforms: planners, parsers, generators
│   └── Services/            ← orchestrators that compose Logic + System
├── vch/                     ← thin ArgumentParser shell, calls Core
│   ├── VchCLI.swift         ← @main root command
│   ├── Commands/            ← one file per subcommand (or related cluster)
│   └── Support/             ← CLI plumbing (CLIBridge, PlanLauncher, completion)
└── vch-xcodebuild-shim/     ← standalone, no deps, exec replacement
```

The four sub-buckets in `VibeChardCore/` are organisational only — there
is one Swift module. Cross-bucket imports are unrestricted; the buckets
just keep the file list scannable. Rough rule of thumb: **Domain** has
no IO, **Logic** has no IO, **System** wraps a single IO concern
behind a protocol, **Services** compose the previous three to do real
work.

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
one of the **Hard rules 1–10** above, do **not** silently revise it. Surface
the trade-off in the PR description and propose a Q-amendment first.

This ceremony does **not** apply to ordinary command-surface evolution
(new subcommands, new flags, new output fields) during 0.x. Those just
ship behind a CHANGELOG entry. Q-amendment is for the load-bearing rules
— Apple-only, BYO Agent, no telemetry, two deps, three targets, the shim
staying minimal, no config files, the reserved subcommand list,
`~/Library/Developer/` immunity, and the multi-language README sync rule.

## Useful local commands

```sh
swift build -c release         # produce .build/release/{vch,vch-xcodebuild-shim}
swift test --parallel
./.build/release/vch version
./.build/release/vch version --json
```

## License

Apache-2.0. Do not change without an explicit user decision.
