#!/usr/bin/env bash
# Pure assertions for M0.5 PoC. No side effects.
# Exit 0 if all checks pass.
#
# Usage: verify.sh <worktree-path>

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: verify.sh <worktree-path>" >&2
  exit 2
fi

worktree="$1"
isolated_dd="$worktree/.agent-build/DerivedData"
home_dd="$HOME/Library/Developer/Xcode/DerivedData"

fail() { echo "✗ $*" >&2; exit 1; }
pass() { echo "✓ $*"; }

# 1. Isolated DerivedData exists.
[ -d "$isolated_dd" ] || fail "expected $isolated_dd to exist"
pass "isolated DerivedData dir present"

# 2. Isolated DerivedData has Build/ products.
if [ ! -d "$isolated_dd/Build" ]; then
  fail "expected $isolated_dd/Build to exist (xcodebuild did not write here)"
fi
pass "isolated Build/ subdir present"

build_count="$(find "$isolated_dd/Build" -mindepth 1 -maxdepth 3 -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$build_count" -gt 0 ] || fail "Build/ is empty; xcodebuild produced no output here"
pass "isolated Build/ contains $build_count subdirs"

# 3. Home DerivedData should NOT have any BeanLedger-* dir created/modified
#    after this PoC run. We use the worktree's mtime as a coarse cutoff.
if [ -d "$home_dd" ]; then
  cutoff="$(stat -f %m "$worktree/.agent-build")"
  newer_count=0
  while IFS= read -r dir; do
    mtime="$(stat -f %m "$dir")"
    if [ "$mtime" -ge "$cutoff" ]; then
      newer_count=$((newer_count + 1))
      echo "  unexpected fresh dir: $dir (mtime=$mtime)" >&2
    fi
  done < <(find "$home_dd" -maxdepth 1 -name 'BeanLedger-*' -type d 2>/dev/null)

  if [ "$newer_count" -gt 0 ]; then
    fail "$newer_count BeanLedger-* dirs in $home_dd were touched during PoC; isolation leaked"
  fi
  pass "home DerivedData was not touched by PoC build"
else
  pass "home DerivedData absent (nothing to leak into)"
fi
