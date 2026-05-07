# `scripts/render-docs-images/`

One-shot renderer for the localized screenshots embedded in the top-level
READMEs. **Not part of `vch`'s build or test pipeline** — only run by hand
when README copy changes, a new locale is added, or a font tweak is needed.

## What it produces

Three PNGs per locale (`en`, `zh-CN`, `zh-TW`, `ja`, `ko`), written to
`<repo>/docs/images/`:

- `hero.<locale>.png` — wide “without vch / with vch” README banner
- `vch-list.<locale>.png` — terminal mockup of `vch list` + `vch state`
- `architecture.<locale>.png` — 5-layer isolation diagram

The square images (`vch-list`, `architecture`) are `1080×1440 @2x`
(effective `2160×2880`). The hero is `1920×800 @2x`
(effective `3840×1600`). All have a dark gradient background.

## Run it

```sh
cd scripts/render-docs-images
npm install                     # pulls Playwright + Chromium
node build.js                   # writes 15 PNGs into ../../docs/images/
```

You'll see one line per produced file:

```
vch-list.en.png  (441.8 KB)
architecture.en.png  (421.5 KB)
...
```

## Editing copy

All locale-specific strings live in three tables at the top of `build.js`:

- `THERO` — text for `hero.<locale>.png`
- `T2` — text for `vch-list.<locale>.png`
- `T3` — text for `architecture.<locale>.png`

`H1_SIZE` (square images) and `HERO_SIZE` (hero banner) let you per-locale
tune the title font size if a longer translation overflows the canvas.
The CJK locales force a `<br/>` between the leading phrase and the `<em>`
highlight to avoid mid-word breaks.

## Why a Node script in a Swift repo?

Pure pragmatism — Playwright + headless Chromium is the only reliable
way I found to render Apple system fonts (`-apple-system`, `PingFang SC`,
`Hiragino Sans`, `Apple SD Gothic Neo`) consistently to PNG. No native
macOS toolchain offers an equivalent CLI without dragging in Xcode UI
tests. This script never runs in CI; it has zero impact on `vch`'s
runtime, build, or test surface.

## Adding a new locale

1. Add the locale code to `LOCALES`.
2. Add an entry to `THERO`, `T2`, `T3`, `H1_SIZE`, and `HERO_SIZE`.
3. Add the matching `<img src="docs/images/hero.<locale>.png">`,
   `vch-list.<locale>.png`, and `architecture.<locale>.png` references
   to `README.<locale>.md`.
4. `node build.js`.
