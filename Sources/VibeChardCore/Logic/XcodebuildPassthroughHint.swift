import Foundation

/// Detect when a user has passed an obvious `xcodebuild` flag
/// directly to `vch test` instead of routing it through the
/// `vch test … -- <xcodebuild flags…>` pass-through, and produce a
/// hint pointing them at the right invocation shape (#86).
///
/// Why this exists: `xcodebuild` flags are *single-dash* longopts
/// (`-only-testing`, `-resultBundlePath`, `-testPlan`, …) and vch
/// otherwise uses GNU-style `--double-dash` options. When a user
/// reaches for a familiar xcodebuild flag, two cliffs combine:
///
///   1. ArgumentParser rejects `--only-testing` (or any of the
///      single-dash forms) with "Unknown option …".
///   2. The fix is `vch test … -- -only-testing <id>` — both the
///      `--` separator and the *single*-dash flag are easy to miss
///      from the usage line.
///
/// The most common flag (`--only-testing`) is now a first-class vch
/// option (#86) so the cliff is gone for that case. This helper
/// catches the long tail: when ArgumentParser rejects an invocation
/// containing one of the *other* common xcodebuild flags, vch prints
/// a hint suggesting the pass-through form.
///
/// The detector is intentionally a pure function over argv so it can
/// be exercised cheaply from unit tests; the CLI wires it in on the
/// `parseAsRoot` error path inside `VchCLI.main()`.
public enum XcodebuildPassthroughHint {

    /// Canonical xcodebuild forms (single-dash) that we recognize as
    /// "user clearly meant to pass this through". Stored with native
    /// xcodebuild casing because we want to echo the exact spelling
    /// back in the hint — `xcodebuild -testPlan` is camelCase,
    /// `xcodebuild -only-testing` is kebab-case, and users who
    /// remember the right name should see the right name.
    private static let knownXcodebuildFlags: Set<String> = [
        "-only-testing",
        "-skip-testing",
        "-only-test-configuration",
        "-skip-test-configuration",
        "-testPlan",
        "-resultBundlePath",
        "-derivedDataPath",
        "-clonedSourcePackagesDirPath",
        "-destination",
        "-test-iterations",
        "-retry-tests-on-failure",
        "-parallel-testing-enabled",
        "-parallel-testing-worker-count",
    ]

    /// Flags vch already exposes as first-class double-dash options
    /// on `vch test`. We skip them in the scan because ArgumentParser
    /// accepts them directly — the only error path involving them is
    /// "missing value", where a `-- -flag <value>` suggestion would
    /// be actively misleading (the user should just supply the
    /// value, not detour through the pass-through).
    ///
    /// Stored in canonical xcodebuild form (single-dash) so the
    /// canonicalization in `scan` lines up regardless of whether the
    /// user typed `--only-testing` or `-only-testing`.
    private static let firstClassOnTestCommand: Set<String> = [
        "-only-testing",
        "-skip-testing",
    ]

    /// Scan `argv` (everything *after* the `test` subcommand token —
    /// e.g. `["foo", "--testPlan", "MyPlan"]`) for an xcodebuild
    /// flag the user almost certainly meant to pass through. Returns
    /// a multi-line hint string suitable for writing to stderr, or
    /// `nil` if nothing looks pass-through-shaped.
    ///
    /// Stops at the first `--` token: anything beyond that is already
    /// pass-through territory and the user has the syntax right.
    ///
    /// Two shapes of hint:
    ///   • If the canonical xcodebuild flag has a first-class vch
    ///     equivalent (e.g. user typed `-only-testing`, which fails
    ///     parsing because the GNU-style scanner reads `-o -n -l …`),
    ///     suggest the first-class double-dash form.
    ///   • Otherwise (e.g. `-testPlan`, `--resultBundlePath`),
    ///     suggest routing through `vch test … -- -<flag> <value>`.
    public static func hintForTestArgv(_ argv: [String]) -> String? {
        for tok in argv {
            if tok == "--" { return nil }
            guard tok.hasPrefix("-") else { continue }
            let canonical = canonicalize(tok)
            // First-class flag the user wrote in single-dash form
            // (xcodebuild style). ArgumentParser will fail; point
            // them at the double-dash vch flag instead of the
            // pass-through dance — it's one keystroke away and
            // doesn't require the `--` separator.
            //
            // Double-dash form (e.g. `--only-testing`) is accepted
            // by ArgumentParser; we never reach this path for it,
            // but guard explicitly so the function stays total.
            if firstClassOnTestCommand.contains(canonical) {
                if tok.hasPrefix("--") {
                    continue
                }
                return formatFirstClassHint(
                    xcodebuildForm: canonical,
                    userToken: tok
                )
            }
            if knownXcodebuildFlags.contains(canonical) {
                return formatPassthroughHint(
                    xcodebuildForm: canonical,
                    userToken: tok
                )
            }
        }
        return nil
    }

    /// Normalize a user-typed token to canonical xcodebuild form. We
    /// only fold the leading-dash count (`--foo` → `-foo`); case is
    /// preserved so `-testPlan` and `-testplan` stay distinguishable
    /// (xcodebuild is case-sensitive).
    private static func canonicalize(_ token: String) -> String {
        if token.hasPrefix("--") {
            return "-" + String(token.dropFirst(2))
        }
        return token
    }

    private static func formatPassthroughHint(xcodebuildForm: String, userToken: String) -> String {
        """
        hint: '\(userToken)' looks like an xcodebuild flag. Pass it through after `--`:
            vch test <name> [vch flags] -- \(xcodebuildForm) <value>
        """
    }

    private static func formatFirstClassHint(xcodebuildForm: String, userToken: String) -> String {
        // xcodebuildForm is `-only-testing`; the vch first-class form
        // is the same name with one extra leading dash.
        let vchForm = "-" + xcodebuildForm
        return """
        hint: '\(userToken)' is the xcodebuild form. vch exposes it as a first-class flag:
            vch test <name> [vch flags] \(vchForm) <value>
        """
    }

    // MARK: - #89: generic unknown-option hint

    /// What downstream tool consumes the `-- <extra-args>` tail of a
    /// vch subcommand. Drives the wording of
    /// `genericUnknownOptionHint` so the suggestion matches where
    /// the user's bytes will actually end up.
    public enum Downstream: String, Equatable {
        /// `vch build` / `vch test` — args after `--` go to xcodebuild.
        case xcodebuild
        /// `vch run` — args after `--` are forwarded verbatim to
        /// `simctl launch`, i.e. to the launched app's main().
        case appLaunchArgs
    }

    /// Map a top-level vch subcommand token to the downstream that
    /// consumes its `-- <extra-args>` tail. Returns `nil` for
    /// subcommands that have no pass-through tail (e.g. `list`,
    /// `state`) — those should never get the unknown-option hint
    /// because there's no `--` plan for the user to be reaching for.
    ///
    /// Single source of truth; `VchCLI.main` reads this rather than
    /// carrying its own copy (AGENTS.md discipline #6).
    public static func downstream(forCommand command: String) -> Downstream? {
        switch command {
        case "build", "test": return .xcodebuild
        case "run": return .appLaunchArgs
        default: return nil
        }
    }

    /// Generic fallback hint for the `vch <build|test|run>` error
    /// path where the user wrote an option vch doesn't know
    /// (e.g. `--extra`) and ArgumentParser rejected it with the
    /// bare "Unknown option" diagnostic (#89).
    ///
    /// The #86-era `hintForTestArgv` only fires for a curated set of
    /// real xcodebuild flag spellings (`-testPlan`, `-resultBundlePath`,
    /// …). For everything else — a user-invented flag like `--extra`,
    /// or any obscure xcodebuild flag not on the list — we still want
    /// to nudge them toward the pass-through form rather than make
    /// them re-read `--help`. That nudge is this function.
    ///
    /// Returns `nil` (no hint) when:
    ///   • `errorMessage` doesn't contain `Unknown option '…'` —
    ///     different validation failure, different problem, no
    ///     pass-through nudge.
    ///   • ArgumentParser already proposed a typo correction
    ///     (`Did you mean '--scheme'?`). That's the higher-signal
    ///     diagnostic and we don't want to compete with it.
    ///   • The extracted token doesn't look like a flag (defensive
    ///     guard against future error-message format changes).
    public static func genericUnknownOptionHint(
        command: String,
        errorMessage: String,
        downstream: Downstream
    ) -> String? {
        // AP's typo correction is the better diagnostic — defer to it.
        if errorMessage.contains("Did you mean") { return nil }

        // Extract the rejected token from the "Unknown option '<tok>'"
        // diagnostic. We parse the message rather than scan argv
        // because AP picks the offending token on its own (it may
        // skip past tokens it recognizes); echoing AP's choice keeps
        // the hint's `'<tok>'` byte-identical to the error line just
        // above it.
        guard let unknownRange = errorMessage.range(of: "Unknown option '") else {
            return nil
        }
        let afterMarker = errorMessage[unknownRange.upperBound...]
        guard let closingQuote = afterMarker.firstIndex(of: "'") else {
            return nil
        }
        let token = String(afterMarker[afterMarker.startIndex..<closingQuote])
        guard token.hasPrefix("-"), token.count > 1 else { return nil }

        let canonical = canonicalize(token)
        let taskUsage = ["build", "test", "run"].contains(command)
            ? "[<name>]"
            : "<name>"
        switch downstream {
        case .xcodebuild:
            return """
            hint: '\(token)' is not a vch flag. To forward an argument to xcodebuild, pass it after `--`:
                vch \(command) \(taskUsage) [vch flags] -- \(canonical) <value>
            """
        case .appLaunchArgs:
            return """
            hint: '\(token)' is not a vch flag. To forward an argument to the launched app, pass it after `--`:
                vch \(command) \(taskUsage) [vch flags] -- \(canonical) <value>
            """
        }
    }
}
