# VibeChard 25-second README demo (VHS).
#
# Renders a colorized terminal recording showcasing `vch new`, parallel
# `vch list`, and `vch state` against the new ANSI palette shipped in
# v0.1.x. Output: <repo>/docs/images/demo.gif (committed alongside README).
#
# Prereq: VHS (https://github.com/charmbracelet/vhs) plus a real VibeChard
# install on $PATH and an Apple project at $VCH_DEMO_PROJECT (defaults to
# ./fixtures/demo-app under this directory). The script intentionally stays
# under 30 seconds so GitHub renders the GIF inline.
#
# Run: cd scripts/vhs-demo && vhs demo.tape

# Output is resolved relative to the .tape file, so this lands at the
# top-level docs/images/demo.gif regardless of where vhs is invoked from.
Output ../../docs/images/demo.gif

# Visual config — keeps the recording on-brand with the README hero.
# Tokyo Night's deep-blue background (#1a1b26) sits in the same family as
# the hero gradient (#0b1220 → #131c2e); blue/green/yellow/magenta accents
# make the new ANSI columns in `vch list` pop.
# Theme list: https://github.com/charmbracelet/vhs/blob/main/THEMES.md
Set Theme "TokyoNight"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 24
Set TypingSpeed 75ms
Set PlaybackSpeed 1.0
Set Shell zsh
Set CursorBlink true

# 1. Workspace overview — empty.
Type "cd ${VCH_DEMO_PROJECT:-./fixtures/demo-app}"
Sleep 300ms
Enter
Sleep 400ms
Type "clear"
Enter
Sleep 600ms

# 2. Spin up two parallel agent worktrees. (No --exec to keep the demo
#    self-contained; the user can imagine `--exec "claude"` here.)
Type "vch new add-paywall"
Sleep 300ms
Enter
Sleep 1800ms
Type "vch new fix-toast"
Sleep 300ms
Enter
Sleep 1800ms

# 3. Show the parallel landscape. This is where the new ANSI colors
#    pay off: NAME is bright blue, BRANCH magenta, SIM yellow, BUILD
#    green/red, header gray. Give the eye time to scan all four columns.
Type "vch list"
Sleep 300ms
Enter
Sleep 3500ms

# 4. Drill into one task's state — last build / last test / last exec.
#    Five+ rows of detail; needs a beat for the viewer to read.
Type "vch state add-paywall"
Sleep 300ms
Enter
Sleep 3500ms

# 5. One-shot exec inside the isolated worktree (build flags get auto-
#    injected by the PATH shim — no extra args from the user).
Type "vch exec add-paywall -- swift --version"
Sleep 300ms
Enter
Sleep 2500ms

# 6. Clean up. Two commands, both worktrees + sim clones gone.
Type "vch remove fix-toast"
Sleep 300ms
Enter
Sleep 1800ms
Type "vch remove add-paywall"
Sleep 300ms
Enter
Sleep 1800ms

# 7. Final empty list — visual proof that nothing leaks behind.
Type "vch list"
Sleep 300ms
Enter
Sleep 2800ms
