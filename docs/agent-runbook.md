# VibeChard Agent Runbook

Operational guide for AI agents working inside user Apple projects with
`vch`. This document is versioned with the CLI; run `vch runbook` to get
the copy that matches the installed binary.

> **Note on languages.** This document is English-only on purpose —
> see [AGENTS.md rule #10](../AGENTS.md). Localized READMEs link here,
> but this file remains the single source of truth.

## First rule

Prefer `vch build`, `vch test`, `vch run`, and `vch logs` for normal
Apple build loops. Use raw `xcodebuild` only from inside `vch <name>` or
`vch exec <name> -- ...`, where the PATH shim and task-local caches are
active.

## Find this runbook

```sh
vch runbook
vch runbook --json
echo "$VCH_AGENT_RUNBOOK_URL"   # set inside vch task environments
```

The URL is tag-pinned to the `vch` binary version, so agents do not read
`master` docs that may describe a newer CLI.

The `homebrew` field in `vch runbook --json` is a shell expression;
expand it in a shell context before using it as a file path.

## Start a task

From the main worktree of a git-tracked Apple project:

```sh
vch new fix-login
vch fix-login
```

To spawn an agent directly inside the isolated worktree:

```sh
vch new fix-login --exec "claude"
```

If another tool already created the linked worktree, stand inside that
worktree and register it:

```sh
vch new --adopt-current
```

## Work loop

```sh
vch build fix-login --scheme MyApp
vch test  fix-login --scheme MyApp --device "iPhone 16"
vch logs  fix-login --test
```

Run a subset of tests:

```sh
vch test fix-login --scheme MyApp --device "iPhone 16" \
  --only-testing MyAppTests/LoginTests
```

Pass an xcodebuild option that vch does not expose directly after `--`:

```sh
vch test fix-login --scheme MyApp --device "iPhone 16" -- -testPlan Smoke
```

Run the app on the task's simulator clone:

```sh
vch run fix-login --scheme MyApp --device "iPhone 16" -- -UITestMode
```

If the requested device type and runtime are installed but no base
simulator exists yet, pass the runtime explicitly. vch will create the
base simulator before cloning it for the task:

```sh
vch test fix-login --scheme MyApp --device "iPhone 17" --runtime "iOS 26.5"
```

Open the worktree in Xcode for manual inspection or to read build logs:

```sh
vch open fix-login
```

## Inspect task state

Prefer the stable accessors over reading `.vch/state.json` by hand:

```sh
vch list --git-status
vch path fix-login
vch state fix-login --field path
vch state fix-login --field simulator.udid
vch sim info fix-login
```

When a task owns multiple simulator bindings, pass selectors:

```sh
vch test fix-login --scheme WatchApp --device "Apple Watch Series 10"
vch sim info fix-login --device "Apple Watch Series 10"
```

If vch reports that a binding is ambiguous, re-run with the listed
`--device` and, when needed, `--runtime`.

## Keep a task current

```sh
vch sync fix-login
```

Use `--dry-run` first when the task has a long-lived branch or when the
base moved substantially.

## Reset local build or simulator state

```sh
vch clean fix-login --all
vch sim erase fix-login --device "iPhone 16"
```

Use these instead of deleting random directories under
`~/Library/Developer`. VibeChard owns task-local scratch under `.vch/`
and `.agent-build/`; CoreSimulator device storage is managed through
`simctl`.

## Finish a task

When the task branch is ready to merge:

```sh
vch land fix-login
```

If a human should review first:

```sh
git -C "$(vch path fix-login)" status --short
vch open fix-login
```

If the task is abandoned:

```sh
vch remove fix-login
```

For tasks registered with `vch new --adopt-current`, `vch remove`
unregisters vch and deletes only `.vch/` and `.agent-build/`. The
external git worktree and branch remain in place; use git directly if
the user also wants those removed.

Clean up already-merged tasks:

```sh
vch prune
vch prune --rm
```

## Do not

- Do not run raw `xcodebuild` from the main worktree for a vch task.
- Do not manually share DerivedData, ModuleCache, SwiftPM caches, or
  result bundles across tasks.
- Do not edit `.vch/state.json` directly unless explicitly debugging
  corrupted state; prefer `vch state`, `vch repair`, and `vch doctor`.
- Do not delete simulator devices by guessing UDIDs; use `vch sim ...`,
  `vch remove`, `vch land`, or `vch doctor --clean`.
