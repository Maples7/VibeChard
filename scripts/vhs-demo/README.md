# `scripts/vhs-demo/`

[VHS](https://github.com/charmbracelet/vhs) tape that produces the
`docs/images/demo.gif` shown in the top-level READMEs. **Not part of
`vch`'s build or test pipeline** — only run by hand when CLI output
changes (e.g., colors, columns, command flags).

## Render it

```sh
brew install vhs           # one-time
cd scripts/vhs-demo
VCH_DEMO_PROJECT=/path/to/some/Apple/project vhs demo.tape
```

The output GIF lands at `<repo>/docs/images/demo.gif`. Commit it
alongside the matching README change.

## Why a demo project is required

The tape calls real `vch new` / `vch list` / `vch remove` against a
git-tracked Apple project — the colors and rows have to come from the
actual binary, not a mockup. We keep this out of CI for the same reason
`render-docs-images` is out of CI: it touches Xcode and would balloon
runtime for zero day-to-day value.

## Editing copy

All voice-overs are inline comments inside `demo.tape`. To change the
beats, edit the `Type` / `Sleep` / `Enter` sequence; VHS turntable docs:
<https://github.com/charmbracelet/vhs#commands>.

The recording is intentionally kept under 30 seconds so GitHub renders
the GIF inline in the README without any user click required.
