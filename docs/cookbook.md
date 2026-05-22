# VibeChard Cookbook

Patterns that aren't a built-in command but come up enough to write
down. For the day-to-day flow, see the
[Quickstart in the README](../README.md#quickstart).

> **Note on languages.** This document is English-only on purpose —
> see [AGENTS.md rule #10](../AGENTS.md). The 5-locale READMEs link
> to the relevant section here when they need to reference a recipe.

## Recipes

- [Branching off mid-WIP work](#branching-off-mid-wip-work)
- [Running a subset of tests](#running-a-subset-of-tests)
- [Keeping a long-running task current](#keeping-a-long-running-task-current)
- [Preserving generated artifacts when landing](#preserving-generated-artifacts-when-landing)
- [Skipping the first-boot delay with warm simulator templates](#skipping-the-first-boot-delay-with-warm-simulator-templates)
- [Resetting per-task simulator state](#resetting-per-task-simulator-state)
- [When `simctl clone` says the template is "Booted"](#when-simctl-clone-says-the-template-is-booted)
- [Cleaning up tasks whose branches have already merged](#cleaning-up-tasks-whose-branches-have-already-merged)

## Branching off mid-WIP work

You're partway through `agent/foo` and want to spawn
`agent/foo-experiment` from foo's **current uncommitted state**, not
just its committed history. `vch new --base agent/foo` only carries
committed history; the uncommitted diff (and any untracked files)
needs the stash dance:

```sh
cd "$(vch path foo)"
git stash push --include-untracked -m "fork-checkpoint"

vch new foo-experiment --base agent/foo

cd "$(vch path foo-experiment)"
git stash apply              # apply, don't pop — leaves the entry intact

cd "$(vch path foo)"
git stash pop                # restore foo's WIP
```

`apply` + `pop` lets one checkpoint land in both worktrees. If you
don't care about restoring foo, drop the final `git stash pop` and
use `git stash drop` instead.

This isn't a `vch fork` because the atomic "transfer staged +
unstaged + untracked + selectively-ignored" operation has no native
git primitive — see [#27](https://github.com/Maples7/VibeChard/issues/27)
for the full discussion. The recipe above is the stable manual
fallback.

## Running a subset of tests

`vch test` exposes the two most common test selectors as first-class
flags ([#86](https://github.com/Maples7/VibeChard/issues/86)):

```sh
# Only one test class:
vch test foo --scheme MyApp --device 'iPhone 16' \
  --only-testing MyAppTests/MyClass

# Only one Swift Testing function:
vch test foo --scheme MyApp --device 'iPhone 16' \
  --only-testing 'MyAppTests/MyClass/myFunc()'

# Skip a slow suite while running the rest:
vch test foo --scheme MyApp --device 'iPhone 16' \
  --skip-testing MyAppTests/SlowSuite

# Combine — repeat the flag, mix with --skip-testing:
vch test foo --scheme MyApp --device 'iPhone 16' \
  --only-testing MyAppTests/Critical \
  --only-testing MyAppTests/Smoke \
  --skip-testing MyAppTests/Critical/flakyCase
```

Each `--only-testing` / `--skip-testing` is translated verbatim to
`xcodebuild -only-testing:<id>` / `-skip-testing:<id>`, so the
identifier shape is exactly what xcodebuild accepts
(`Target/Suite`, `Target/Suite/case()`, `Target/Suite/case`).

For any *other* xcodebuild flag, pass it after a literal `--` using
the single-dash xcodebuild form:

```sh
# Pin a test plan + disable parallel testing for one run:
vch test foo --scheme MyApp --device 'iPhone 16' \
  -- -testPlan SmokePlan -parallel-testing-enabled NO
```

If you reach for an xcodebuild flag directly (e.g. `--testPlan`),
vch will emit an actionable hint pointing at the right invocation
shape instead of just rejecting the flag.

Prefer `vch test` over raw `vch exec <task> -- xcodebuild test ...`
for everyday rerun loops: the high-level command clears vch's
task-local result bundle when needed, writes the full firehose to
`.vch/last-test.log`, and prints the result bundle path in the
summary. Raw `vch exec` remains useful as an escape hatch, but it
does not tee or summarize xcodebuild output.

Once you have a failing run, `vch test foo --rerun-failed` replays
only the failed cases without re-typing the identifier — vch reads
them out of the recorded xcresult bundle.

## Keeping a long-running task current

If `agent/<name>` lives long enough that its base branch has moved
on, `vch sync <name>` fetches the recorded base's upstream and
rebases the task branch onto it — without touching your main
worktree:

```sh
vch sync foo                          # fetch + rebase
vch sync foo --dry-run                # preview ahead/behind + plan
vch sync foo --merge                  # use git merge --no-ff instead
                                      # (only if you've pushed agent/foo)
vch sync foo --onto origin/release-2  # one-off retarget
vch sync foo --no-fetch               # offline, against already-fetched refs
```

The default policy is "rebase, no force, no autostash" — vch never
rewrites or hides your work. If git refuses (uncommitted changes,
conflicts), the operation aborts cleanly and you finish the rebase
inside the task worktree by hand. Successful runs record a `lastSync`
block in `state.json` (visible via `vch state <name>`).

## Preserving generated artifacts when landing

`vch land` only carries **committed** content into the destination
branch. Anything in the task worktree that isn't tracked by git —
uncommitted changes, untracked files, and anything excluded by
`.gitignore` (regenerated images, build outputs, caches) — is **not**
part of the merge, and on a successful land the default `vch rm` step
deletes the worktree along with all of that.

This bites a specific shape of workflow: a script in the task worktree
regenerates artifacts that are deliberately `.gitignore`d in the repo.
You confirm the new artifacts look good, run `vch land`, and only
afterwards realise the regenerated files never made it across the
merge — the new artifacts went away with the worktree, and main is
still showing the old ones.

If you need those artifacts on the destination branch's worktree, ask
vch not to delete the worktree until you've copied them out:

```sh
vch land foo --keep                              # merge but keep agent-foo/
rsync -a "$(vch path foo)/docs/images/" \
      docs/images/                               # copy what you actually want
vch rm foo                                       # then clean up
```

Pick whichever copy tool fits — `cp -R`, `tar -c | tar -x`, `git lfs
migrate`, etc. vch deliberately doesn't take a side on which artifacts
"should" be copied or how, because the answer depends on what your
project ignores and why.

## Skipping the first-boot delay with warm simulator templates

The first time you run `vch test` against a freshly-cloned simulator,
~30 s of that wallclock is `simctl create` + first-boot cache
priming, *not* your build. If you spin up multiple agents in parallel
on the same `(device, runtime)` pair, you pay that cost once per
task. A "warm template" pre-pays it once for the whole machine.

```sh
# One-time setup (per device/runtime pair you actually use):
vch sim warm-template create "iPhone 16" --runtime "iOS 26.4"

# Now every task that pins that runtime saves ~21 s on its first
# `vch test` — the per-task clone inherits the primed caches.
vch test add-paywall  --device "iPhone 16" --runtime "iOS 26.4"
vch test fix-crash    --device "iPhone 16" --runtime "iOS 26.4"

# Inspect what's currently cached:
vch sim warm-template list

# Free the disk back when you don't need it any more:
vch sim warm-template remove "iPhone 16" --runtime "iOS 26.4"
```

The same recipe works on **watchOS, tvOS, and visionOS** (#58); just
swap the device name and runtime label:

```sh
vch sim warm-template create "Apple Watch Series 10 (46mm)" --runtime "watchOS 11.5"
vch sim warm-template create "Apple TV 4K (3rd generation)" --runtime "tvOS 18.0"
vch sim warm-template create "Apple Vision Pro"             --runtime "visionOS 2.5"
```

Lifetime is **decoupled** from any task. `vch remove` and
`vch doctor --clean` never touch warm templates — you create them,
you delete them. `vch doctor` lists them so you can spot stale or
booted ones, but never auto-cleans (a clean would silently destroy
the priming work). The `--runtime` argument is mandatory because
different runtimes for the same device produce different warm
templates; without a pin, vch would have nothing unambiguous to look
up.

Empirical savings vary by platform — measured medians:

| Platform | Cold path | Warm path | Savings |
|---|---|---|---|
| iOS (iPhone 16 + iOS 26.4, N=5)              | 30.75 s | 9.41 s  | 21.35 s (69.4 %) |
| watchOS (Apple Watch Series 10 (46mm) + watchOS 11.5, N=3) | 31.0 s  | 23.3 s  | 7.7 s (24.9 %)   |

watchOS first-boot does less cache priming work than iOS, so the
absolute win is smaller — but still well above the 2 s noise floor
that would have made the optimisation pointless. tvOS and visionOS
should be in the same ballpark (the SPIKE methodology is in PR #58
and runnable with whatever runtimes you have installed).

## Resetting per-task simulator state

A per-task simulator clone (`xcrun simctl clone`) inherits the
**entire `~/Library`** of the template, including `UserDefaults`,
keychain entries, and app containers written by previous runs.
That's exactly what you want for the warm-template fast path
(#47/#58) — the priming work survives — but it occasionally bites
when a test depends on first-launch behaviour:

```
✗ CloudSyncStatusCenterGraceTests.firstLaunchAlertFiresAfterGraceEnds()
   → expected alert flag to be unset, was true
```

…because the template was used interactively for development and
wrote `UserDefaults` keys that the clone now also has.

Reset the per-task clone to a freshly-erased state before the run
with `--erase-clone`:

```sh
vch test add-paywall --erase-clone
vch run  add-paywall --erase-clone
vch build add-paywall --erase-clone
```

`--erase-clone` chains `simctl shutdown` → `simctl erase` (erase
rejects booted devices), so it also collapses any leftover boot
state. Costs ~10–20 s — off by default to keep the fast path fast.
Drop the flag once the test passes; daily runs don't need it.

The same reset is the first recovery step for xcodebuild launch
failures like:

```
SBMainWorkspace Busy ("Application failed preflight checks")
```

When `vch build` / `vch test` recognizes that failure in the log, it
prints a hint to rerun once with `--erase-clone` or reset the clone
explicitly with `vch sim erase <task> --device <template>`.

If you find yourself reaching for `--erase-clone` constantly,
consider keeping a development-only template separate from the
warm template that vch clones from. The warm template should be
treated as immutable — only `vch sim warm-template create` /
`remove` should ever touch it.

## When `simctl clone` says the template is "Booted"

The companion failure mode to inherited state is when **the warm
template is currently running** and `simctl clone` refuses
outright:

```
simulator template 'iPhone 16' (12345678…) is currently Booted —
`xcrun simctl clone` refuses to clone a booted device.
```

This usually means you opened the warm template from
`Simulator.app` (or an Xcode UI test session) earlier and forgot
to shut it down. The fix is `xcrun simctl shutdown <UDID>`, which
takes a second.

If you don't want to context-switch into a terminal every time,
`vch build` / `vch test` / `vch run` accept an opt-in
`--shutdown-template` flag that does the shutdown and retries the
clone for you:

```sh
vch test add-paywall --shutdown-template
```

The flag is **off by default** on purpose: warm templates are
shared across all your active vch tasks (per hard rule #9, vch
never auto-touches a shared resource). If another task's
`vch run` is currently driving the same template, an automatic
shutdown would yank it out from under that task. With the flag
explicit you decide once per invocation.

## Cleaning up tasks whose branches have already merged

After a few `vch land`s (or upstream merges via your usual GitHub /
GitLab flow), it's easy to lose track of which leftover worktrees
are still doing real work and which are just rusting out. `vch list`
alone shows the BUILD column, but not whether the task's branch is
still ahead of its base.

Two complementary tools (#67):

```sh
vch list --git-status              # passive signal: MERGED column
vch prune                          # dry-run: list every safe-to-remove task
vch prune --rm                     # actually remove them
```

`vch prune` only touches tasks whose branch is **fully merged**
into its recorded base. By default it also skips tasks with
uncommitted changes (override with `--allow-dirty`) and tasks where
an editor / shell still has files open inside the worktree
(override with `--force`). The flag vocabulary mirrors `vch rm` so
the two commands behave the same way.

If you'd rather see the merged-state passively next to the rest of
your task list, just add `--git-status` to your usual `vch list` —
the `MERGED` column reads `yes` (merged and clean), `dirty` (merged
commits, uncommitted worktree changes), `no`, or `-` (unknown). The
branch-merge value lands in `git.mergedIntoBase` under
`vch list --json`.
