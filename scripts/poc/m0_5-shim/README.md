# M0.5 — PATH shim PoC

Validates the core technical hypothesis behind VibeChard:

> Putting a fake `xcodebuild` first on `$PATH`, which transparently injects
> `-derivedDataPath` / `-clonedSourcePackagesDirPath` / `-resultBundlePath`
> and execs the real `xcodebuild`, works on a real Apple project.

If this PoC fails, the product positioning needs to fall back to "ask the
agent to call `vch build`" (a much weaker guarantee).

## Files

- `shim/xcodebuild` — 50-ish-line bash shim. Reads three env vars, optionally
  injects matching flags, then `exec`s the real `xcodebuild` resolved via
  `/usr/bin/xcrun -f xcodebuild` (bypasses PATH, no recursion).
- `run-poc.sh` — orchestrator that:
    1. Creates a throwaway git worktree of BeanLedger at
       `../BeanLedger-vch-poc` on branch `agent/vch-poc`
    2. Activates the shim on PATH
    3. Runs `xcodebuild -showBuildSettings` (cheap transparency probe)
    4. Runs a real `xcodebuild build` for the iOS Simulator destination
    5. Asserts DerivedData materialized inside the isolated path
- `verify.sh` — pure assertions, no side effects, callable independently.

## How to run

```sh
cd /Users/maples7/src/VibeChard
./scripts/poc/m0_5-shim/run-poc.sh
```

## Cleanup

```sh
./scripts/poc/m0_5-shim/run-poc.sh --clean
```

removes `../BeanLedger-vch-poc` worktree and the `agent/vch-poc` branch.

## Pass/fail criteria

PoC passes iff:

- `xcodebuild -showBuildSettings` exit 0, output unchanged vs unshimmed run
- `xcodebuild build` exits 0
- `<worktree>/.agent-build/DerivedData/Build/` exists and is populated
- the user's home `~/Library/Developer/Xcode/DerivedData/BeanLedger-*/`
  directory **does NOT** receive new build products from this run
- shim handles user-supplied `-derivedDataPath` without double-injection
