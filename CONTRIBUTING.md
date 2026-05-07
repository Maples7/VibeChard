# Contributing to VibeChard

Thanks for poking around. This document is short on purpose: VibeChard
is a small tool with a small surface, and the rules of the road are
deliberately boring so that contributions — human or AI — stay
predictable.

If you're an AI agent: read [`AGENTS.md`](AGENTS.md) **first**. The
locked rules there override anything below if they ever conflict.

## Branching model

We use a stripped-down [GitHub flow](https://githubflow.github.io/):

- `master` is the only long-lived branch. It is **always
  releasable** — every commit on it has a green CI build.
- All changes land via pull request. **Do not push directly to
  `master`** (the only allowed exception is `chore(release): x.y.z`
  commits, see [Releases](#releases) below).
- Feature work happens on short-lived branches off `master`. Delete
  them after merge.
- We do **not** use `develop`, `release/*`, or `hotfix/*` branches.
  If we ever need to maintain an older minor (e.g. patches to
  `0.1.x` after `0.2.0` ships) we'll open `support/0.1.x` then —
  YAGNI until then.

```
master ──●──●─────●────●─────●──●──   (protected; CI must pass)
         │  │     │    │     │
         └──┘     │    │     └── tag v0.1.4 → release.yml builds
                  │    │            artifacts + bumps tap
                  └────┘
            feat/colorize    fix/timestamps
            (PR → squash)    (PR → squash)
```

### Branch names

Use the same prefixes as Conventional Commits so a glance at
`git branch` tells you the change type:

| Prefix       | When                                |
|--------------|-------------------------------------|
| `feat/…`     | New user-visible capability         |
| `fix/…`      | Bug fix                             |
| `docs/…`     | README / CHANGELOG / comments only  |
| `refactor/…` | Internal restructuring, no behavior |
| `test/…`     | New or rewritten tests              |
| `chore/…`    | Tooling, deps, release commits      |
| `ci/…`       | `.github/workflows/*` only          |

Examples: `feat/copy-untracked`, `fix/exec-tty-hang`,
`docs/zh-tw-readme`, `chore/release-0.1.4`.

## Commit messages

[Conventional Commits 1.0](https://www.conventionalcommits.org/en/v1.0.0/).

```
<type>(<scope>): <subject>

<body — explain WHY, not what>

<optional footer: BREAKING CHANGE, Closes #123>
```

- `<type>` matches the branch prefix (`feat`, `fix`, `docs`,
  `refactor`, `test`, `chore`, `ci`, `build`, `perf`, `style`).
- `<scope>` is one of: `cli`, `core`, `shim`, `new`, `exec`, `build`,
  `test`, `sim`, `doctor`, `open`, `state`, `completions`,
  `shellenv`, `release`. Multi-scope changes can omit `(scope)`.
- Subject ≤ 72 chars, imperative mood, no trailing period.
- Body wrapped at 72 chars, multiple `-m` flags is fine.

`BREAKING CHANGE:` in the footer triggers a major bump per SemVer
(but until `1.0.0`, breaking changes go in a minor — see [Versioning](#versioning)).

## Pull requests

- Open PRs against `master`.
- Keep them small and reviewable. If you find yourself adding three
  unrelated changes, split them.
- The PR description should answer: **what changed, why, and how
  was it verified?** Paste the relevant `swift test` output.
- All squash-merge. The PR title becomes the squashed commit
  subject — make sure it follows the Conventional Commits format
  above.
- Update [`CHANGELOG.md`](CHANGELOG.md) under `## [Unreleased]`
  in the same PR, in the appropriate section
  (`Added` / `Changed` / `Fixed` / `Removed` / `Tests` / `CI` /
  `Docs`). Lines wrap at ~70 chars to match existing entries.

### Tests

`swift test --parallel` must pass locally **and** in CI before
merge. New behavior needs new tests; new public Core API needs unit
coverage in [`Tests/VibeChardCoreTests/`](Tests/VibeChardCoreTests).
Integration tests touching real `git` go under
[`Tests/VibeChardCoreTests/Integration/`](Tests/VibeChardCoreTests/Integration).

The shim has its own integration suite at
[`Tests/ShimIntegrationTests/`](Tests/ShimIntegrationTests). Don't
add Foundation imports there — see
[`AGENTS.md`](AGENTS.md) rule #6.

### Don't

- Don't add new dependencies. We have two
  (`swift-argument-parser`, `swift-system`) and that's the budget.
  See [`AGENTS.md`](AGENTS.md) rule #4.
- Don't expand the target list beyond `VibeChardCore`, `vch`, and
  `vch-xcodebuild-shim`.
- Don't add network calls or telemetry. Ever.
- Don't bypass `git commit -m` hooks (`--no-verify`).
- Don't add docstrings, comments, type annotations, or "while I'm
  here" cleanups to code you didn't otherwise touch.

## Versioning

[Semantic Versioning 2.0](https://semver.org/) once we hit `1.0.0`.

Pre-1.0 (where we are today): **patch bump** for fixes /
docs / internal refactors that don't change CLI surface; **minor
bump** for new flags, new subcommands, or behavior changes that
existing users could feel — even if we'd technically call them
breaking. The minor itself is the warning that "0.x is not stable".

## Releases

Cutting a release is a single-author flow and is the documented
exception to the "no direct pushes to master" rule:

1. **Land everything you want in the release** through PRs first.
   `## [Unreleased]` in CHANGELOG should describe what's in the
   release.
2. On `master`, in one commit:
   - Bump `Sources/VibeChardCore/VibeChard.swift` →
     `public static let version = "x.y.z"`
   - In CHANGELOG, replace the empty `## [Unreleased]` heading with
     `## [Unreleased]` *(re-add it empty)* + `## [x.y.z] - YYYY-MM-DD`,
     and add the compare link `[x.y.z]:
     https://github.com/Maples7/VibeChard/compare/<prev>...<this>`.
   - Update the `[Unreleased]` compare link to start from the new tag.
   - Commit message: `chore(release): x.y.z` with a one-paragraph
     summary in the body.
3. `git tag -a vx.y.z -m "vx.y.z"` and `git push origin master vx.y.z`.

[`release.yml`](.github/workflows/release.yml) does the rest:
verifies the tag matches `VibeChard.version`, runs the test suite
in release mode, creates the GitHub Release, and bumps the formula
in `Maples7/homebrew-tap`. If
`HOMEBREW_TAP_TOKEN` is unset the tap step is skipped — the rest
of the release still completes.

## Local commands

```sh
swift build -c release           # produce .build/release/{vch,vch-xcodebuild-shim}
swift test --parallel            # full suite (must be green)
./.build/release/vch version
./.build/release/vch version --json
```

## Reporting issues

Issues with a clear reproduction, the output of `vch version --json`,
and `sw_vers` get triaged faster. We don't run a private bug tracker —
GitHub Issues is the only channel.

## License

By contributing you agree your contribution is licensed under
Apache-2.0, the same license as the project.
