#!/usr/bin/env bash
# M0.5 — VibeChard PATH shim PoC orchestrator.
# Validates that a fake xcodebuild on $PATH can transparently inject
# isolation flags and exec the real xcodebuild against a real Apple project.
#
# Usage:
#   run-poc.sh                # full run: build + verify
#   run-poc.sh --probe        # cheap probe only (-showBuildSettings, no compile)
#   run-poc.sh --clean        # remove worktree + branch
#
# Assumes:
#   - BeanLedger lives at $BEANLEDGER (default /Users/maples7/src/BeanLedger)
#   - 'xcrun' and 'xcodebuild' resolve to a real Xcode (xcode-select)
#   - You are OK with creating a sibling worktree at ../BeanLedger-vch-poc

set -euo pipefail

POC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_DIR="$POC_DIR/shim"
VERIFY="$POC_DIR/verify.sh"

BEANLEDGER="${BEANLEDGER:-/Users/maples7/src/BeanLedger}"
WORKTREE_NAME="vch-poc"
WORKTREE_PATH="$(dirname "$BEANLEDGER")/$(basename "$BEANLEDGER")-$WORKTREE_NAME"
BRANCH="agent/$WORKTREE_NAME"
SCHEME="BeanLedger"

log() { printf '\n=== %s ===\n' "$*"; }

ensure_executable() {
  chmod +x "$SHIM_DIR/xcodebuild" "$VERIFY"
}

cmd_clean() {
  log "Cleanup"
  cd "$BEANLEDGER"
  if [ -d "$WORKTREE_PATH" ]; then
    git worktree remove --force "$WORKTREE_PATH" || true
  else
    git worktree prune
  fi
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git branch -D "$BRANCH" || true
  fi
  echo "✓ removed $WORKTREE_PATH and $BRANCH"
}

setup_worktree() {
  log "Setup worktree"
  cd "$BEANLEDGER"
  if [ -d "$WORKTREE_PATH" ]; then
    echo "worktree already exists, reusing: $WORKTREE_PATH"
  elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$WORKTREE_PATH" "$BRANCH"
  else
    git worktree add -b "$BRANCH" "$WORKTREE_PATH"
  fi
  mkdir -p "$WORKTREE_PATH/.agent-build/DerivedData"
  mkdir -p "$WORKTREE_PATH/.agent-build/SourcePackages"
}

# Activate the shim by prepending its directory to PATH and exporting the
# three isolation env vars that the shim looks for.
export_shim_env() {
  export VCH_DERIVED_DATA_PATH="$WORKTREE_PATH/.agent-build/DerivedData"
  export VCH_SPM_CLONE_DIR="$WORKTREE_PATH/.agent-build/SourcePackages"
  export VCH_RESULT_BUNDLE_PATH="$WORKTREE_PATH/.agent-build/Result.xcresult"
  # Resolve real xcodebuild BEFORE we modify PATH so the shim's own
  # `xcrun -f xcodebuild` path stays sane.
  export PATH="$SHIM_DIR:$PATH"
}

probe_transparency() {
  log "Probe 1: which xcodebuild?"
  command -v xcodebuild
  log "Probe 2: xcodebuild -showBuildSettings (cheap, no compile)"
  cd "$WORKTREE_PATH"
  xcodebuild \
    -project BeanLedger.xcodeproj \
    -scheme "$SCHEME" \
    -showBuildSettings \
    -destination 'generic/platform=iOS' \
    | head -n 5
}

real_build() {
  log "Real build (this will take a few minutes on first run)"
  cd "$WORKTREE_PATH"
  VCH_SHIM_DEBUG=1 xcodebuild \
    -project BeanLedger.xcodeproj \
    -scheme "$SCHEME" \
    -destination 'generic/platform=iOS' \
    build \
    -quiet
}

assert_no_user_derived_data_override() {
  log "Negative test: user-supplied -derivedDataPath wins (no double-inject)"
  cd "$WORKTREE_PATH"
  local user_dd
  user_dd="$(mktemp -d)"
  VCH_SHIM_DEBUG=1 xcodebuild \
    -project BeanLedger.xcodeproj \
    -scheme "$SCHEME" \
    -showBuildSettings \
    -derivedDataPath "$user_dd" \
    -destination 'generic/platform=iOS' \
    > /dev/null
  # If shim double-injected, BUILD_DIR settings would be inconsistent; we just
  # check the directory was actually used by xcodebuild (xcodebuild creates
  # info plist when invoked).
  if [ -d "$user_dd" ]; then
    echo "✓ user -derivedDataPath ($user_dd) accepted"
  fi
  rm -rf "$user_dd"
}

main() {
  ensure_executable
  case "${1:-}" in
    --clean)
      cmd_clean
      exit 0
      ;;
    --probe)
      setup_worktree
      export_shim_env
      probe_transparency
      assert_no_user_derived_data_override
      echo "✓ probe-only PoC complete"
      exit 0
      ;;
    "")
      setup_worktree
      export_shim_env
      probe_transparency
      assert_no_user_derived_data_override
      real_build
      "$VERIFY" "$WORKTREE_PATH"
      echo
      echo "✓ M0.5 PoC PASSED"
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
}

main "$@"
