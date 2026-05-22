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
8. **Reserved subcommand names.** `vch new <name>` rejects names that
   collide with an existing subcommand or alias, or that start with `-`.
   The authoritative list lives in
   `Sources/VibeChardCore/Domain/TaskName.swift` — read the code, not
   this file, when you need the current set.
9. **Don't touch the user's `~/Library/Developer/` outside the
   simulator-clone exception.** Every byte vch writes directly must
   land inside the worktree's `.vch/` or `.agent-build/`. The single
   permitted footprint under `~/Library/Developer/` is
   `~/Library/Developer/CoreSimulator/Devices/<UDID>/`, because
   `xcrun simctl` does not accept an alternate storage root — there
   is no `--data-dir` or equivalent flag, so the OS owns the layout.

   Within that exception, the *kinds* of vch-managed devices and
   their lifecycle rules (per-task vs. shared, who creates / destroys
   them) are defined in code — see `SimulatorService` and the
   `WarmTemplate*` types under `Domain/`. The load-bearing principle
   is that **the user owns the lifecycle of any shared resource**:
   vch may auto-create and auto-reap state that belongs to a single
   task, but never state that is shared across tasks. New device
   kinds are fine when the trade-off is justified in the PR
   description. `ci.yml` smoke-checks the shim's `xcrun -f xcodebuild`
   exec path on every push to ensure no other directories under
   `~/Library/Developer/` ever get written to by vch.
10. **Multi-language README sync.** Substantive changes to `README.md`
    (features, commands, install steps, rules) must be mirrored to
    `README.ja.md`, `README.ko.md`, `README.zh-CN.md`, `README.zh-TW.md`
    in the same PR. If you cannot translate confidently, add
    `<!-- TODO: sync with README.md -->` at the top of the affected file
    rather than letting it silently drift. Pure typo / link / formatting
    fixes are exempt.

    **Scope: README mainline only.** Extension reference docs under
    `docs/` (e.g. `docs/cookbook.md`, `docs/commands.md`) are
    English-only — the single source of truth lives in English and
    is not mirrored to other locales. The 5-locale READMEs may link
    *to* `docs/...`; the link itself counts as a substantive change
    and must be present in all 5 READMEs, but the target document
    does not need a translated counterpart. The point of this carve-out
    is to keep README a high-quality first-impression artefact in 5
    languages without paying a 5× tax on every advanced-recipe edit.

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
   fixes go under `## Unreleased`. Pure docs and internal refactors
   are exempt. Every CHANGELOG line must be defensible from the
   diff — if a bullet has no matching code, you shipped a lie.
4. **Keep README in sync with the source.** Command-table rows,
   flag descriptions, examples, and architecture claims must reflect
   the current code. The 5-locale sync rule (#10 above) applies to
   any substantive update — but the rule above it is that README
   must not lie about what the binary does.
5. **Worktree + PR workflow, no direct pushes to `master`.** Every
   change — code, docs, tests, CHANGELOG — ships through a pull request
   from a short-lived topic branch, but issue work must be implemented
   inside a dedicated Git worktree created from up-to-date
   `origin/master`:

   ```sh
   git worktree add -b fix/<issue>-<topic> \
     ../VibeChard-fix-<issue>-<topic> origin/master
   ```

   Do the edits, commits, validation, push, and PR creation from that
   worktree so multiple issues can be handled in parallel locally.
   Direct commits pushed to `master` are rejected by the remote; do not
   try to work around the protection (no `--force`, no admin overrides,
   no detour branches that fast-forward `master` locally). If you find
   yourself on `master` with local commits, stop and move that work into
   a dedicated worktree-backed topic branch before opening a PR.
6. **One list, one place.** If a constant, set, or table already
   exists in the codebase, do not retype it elsewhere — `import` it.
   Specifically: the set of reserved subcommand tokens lives in
   `TaskName.reserved` (hard rule #8); the canonical product version
   lives in `VibeChard.version`; the warm-template name pattern
   lives next to `WarmTemplate`. Any "shadow copy" of one of these
   is a bug waiting to drift — v0.5.0 shipped with `vch prune` and
   `vch clean` broken because `TaskShortcutDispatcher` carried a
   second hardcoded copy of the reserved set (#82). The fix was to
   delete the copy and read `TaskName.reserved` directly. When PR
   review spots a literal that resembles a list elsewhere in the
   tree, push back: re-typing is the smell.
7. **No logic in `vch/`.** The `vch` target is an ArgumentParser
   shell: argument parsing, output formatting, exit-code mapping.
   Every decision rule, parser, planner, or transform belongs in
   `VibeChardCore/`. The architectural reason is testability — the
   `vch` executable target cannot be `@testable import`ed (Swift
   restriction) and hard rule #5 forbids extracting a third
   Sources/ target. Logic that lives in `vch/` is logic that
   cannot be unit-tested. The `TaskShortcutDispatcher` regression
   above wasn't just a duplicated list — it was a duplicated list
   in a file no unit test could see. Moving it to
   `VibeChardCore/Logic/` is what made the bug catchable in the
   first place. New code in `vch/` should be a few lines that call
   into Core; if a `Commands/*.swift` file grows a decision tree,
   the decision tree belongs in `Logic/` or `Services/`.
8. **Release docs sweep.** Every release PR must explicitly check
   whether the official Agent runbook (`docs/agent-runbook.md`),
   README family (`README.md` plus localized READMEs when the
   README sync rule applies), command reference (`docs/commands.md`),
   cookbook, and any other user-facing documentation need updates for
   the release contents. Update stale docs in the release PR, or state
   in the PR body that the docs were reviewed and no changes were
   needed. Do not push a release tag when user-facing docs describe a
   different CLI than the version being released.

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
See Engineering discipline #7 — this isn't a style preference, it's the
reason `vch prune` was broken in v0.5.0 (#82) without any test catching it.

## Test layers

| Layer | Where | Runs in CI | Notes |
|---|---|---|---|
| Unit | `Tests/VibeChardCoreTests/` | yes | No IO; protocol fakes only |
| Integration | (later) `Tests/VibeChardCoreTests/Integration/` | yes | Temp git repo + real `/usr/bin/git`; may invoke `xcrun` lazily |
| E2E | manual dogfood against a real Apple project | no | Touches real Xcode + simulators |

## Useful local commands

```sh
swift build -c release         # produce .build/release/{vch,vch-xcodebuild-shim}
swift test --parallel
./.build/release/vch version
./.build/release/vch version --json
```

## License

Apache-2.0. Do not change without an explicit user decision.
