import XCTest
@testable import VibeChardCore

final class XcodebuildPassthroughHintTests: XCTestCase {

    // MARK: - Negative cases (nothing pass-through-shaped)

    func testEmptyArgvReturnsNil() {
        XCTAssertNil(XcodebuildPassthroughHint.hintForTestArgv([]))
    }

    func testJustTaskNameReturnsNil() {
        XCTAssertNil(XcodebuildPassthroughHint.hintForTestArgv(["foo"]))
    }

    /// vch's own flags must never trigger the hint — they're handled
    /// by ArgumentParser directly.
    func testVchFlagsReturnNil() {
        let cases: [[String]] = [
            ["foo", "--scheme", "MyApp"],
            ["foo", "--device", "iPhone 16"],
            ["foo", "--verbose"],
            ["foo", "--rerun-failed"],
            ["foo", "--erase-clone", "--shutdown-template"],
        ]
        for argv in cases {
            XCTAssertNil(
                XcodebuildPassthroughHint.hintForTestArgv(argv),
                "expected no hint for \(argv)"
            )
        }
    }

    /// Tokens after `--` are already in pass-through territory; the
    /// user has the syntax right and we don't want to nag.
    func testFlagsAfterSeparatorReturnNil() {
        XCTAssertNil(
            XcodebuildPassthroughHint.hintForTestArgv(
                ["foo", "--", "-testPlan", "MyPlan"]
            )
        )
        XCTAssertNil(
            XcodebuildPassthroughHint.hintForTestArgv(
                ["foo", "--scheme", "MyApp", "--", "-resultBundlePath", "/tmp/r.xcresult"]
            )
        )
    }

    // MARK: - First-class flags suppress the hint

    /// `--only-testing` is a first-class vch flag (#86), so a missing-
    /// value error on it should NOT trigger a hint suggesting the
    /// user route it through `--`. ArgumentParser's own
    /// "missing value" error is the right diagnostic.
    func testFirstClassOnlyTestingReturnsNil() {
        XCTAssertNil(
            XcodebuildPassthroughHint.hintForTestArgv(
                ["foo", "--only-testing"]
            )
        )
        XCTAssertNil(
            XcodebuildPassthroughHint.hintForTestArgv(
                ["foo", "--only-testing", "MyAppTests/A"]
            )
        )
    }

    func testFirstClassSkipTestingReturnsNil() {
        XCTAssertNil(
            XcodebuildPassthroughHint.hintForTestArgv(
                ["foo", "--skip-testing", "MyAppTests/Slow"]
            )
        )
    }

    // MARK: - Positive cases (hint fires)

    /// The motivating regression from the issue body. After #86,
    /// `--only-testing` is first-class; if the user typed the
    /// *single-dash* xcodebuild form, the hint should point them
    /// at the double-dash vch flag rather than the pass-through.
    func testSingleDashOnlyTestingPointsAtFirstClassFlag() {
        let hint = XcodebuildPassthroughHint.hintForTestArgv(
            ["foo", "-only-testing", "MyAppTests/A"]
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(
            hint!.contains("--only-testing"),
            "hint should mention the first-class double-dash flag: \(hint!)"
        )
        // The hint should NOT push the user toward the pass-through
        // dance — that's the worse ergonomic.
        XCTAssertFalse(
            hint!.contains("Pass it through after `--`"),
            "hint should not suggest the pass-through for first-class flags: \(hint!)"
        )
    }

    func testSingleDashSkipTestingPointsAtFirstClassFlag() {
        let hint = XcodebuildPassthroughHint.hintForTestArgv(
            ["foo", "-skip-testing", "MyAppTests/Slow"]
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("--skip-testing"))
    }

    func testTestPlanFlagFires() {
        let hint = XcodebuildPassthroughHint.hintForTestArgv(
            ["foo", "--testPlan", "MyPlan"]
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("--testPlan"), "hint should echo the user token: \(hint!)")
        XCTAssertTrue(hint!.contains("-testPlan"), "hint should show the canonical xcodebuild form: \(hint!)")
        XCTAssertTrue(hint!.contains("--"), "hint should mention the `--` separator: \(hint!)")
    }

    func testResultBundlePathFires() {
        let hint = XcodebuildPassthroughHint.hintForTestArgv(
            ["foo", "--resultBundlePath", "/tmp/r.xcresult"]
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("-resultBundlePath"))
    }

    func testSingleDashTestPlanFires() {
        let hint = XcodebuildPassthroughHint.hintForTestArgv(
            ["foo", "-testPlan", "MyPlan"]
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("-testPlan"))
    }

    func testParallelTestingFlagFires() {
        let hint = XcodebuildPassthroughHint.hintForTestArgv(
            ["foo", "--parallel-testing-enabled", "NO"]
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("-parallel-testing-enabled"))
    }

    /// The hint fires on the first match; subsequent tokens don't
    /// matter. We don't enumerate every offender.
    func testFiresOnFirstMatchEvenWithEarlierNonFlags() {
        let hint = XcodebuildPassthroughHint.hintForTestArgv(
            ["foo", "--scheme", "MyApp", "--testPlan", "MyPlan"]
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("-testPlan"))
    }

    // MARK: - Casing

    /// xcodebuild flag names are case-sensitive. `-testplan` (lower
    /// case `p`) is not a real flag, so the hint should NOT fire —
    /// otherwise we'd suggest a flag that wouldn't work anyway.
    func testCaseMismatchDoesNotFire() {
        XCTAssertNil(
            XcodebuildPassthroughHint.hintForTestArgv(
                ["foo", "--testplan", "MyPlan"]
            )
        )
    }

    // MARK: - #89: downstream lookup

    func testDownstreamForKnownCommands() {
        XCTAssertEqual(
            XcodebuildPassthroughHint.downstream(forCommand: "build"),
            .xcodebuild
        )
        XCTAssertEqual(
            XcodebuildPassthroughHint.downstream(forCommand: "test"),
            .xcodebuild
        )
        XCTAssertEqual(
            XcodebuildPassthroughHint.downstream(forCommand: "run"),
            .appLaunchArgs
        )
    }

    /// Anything else — `list`, `state`, `path`, `new`, `version`, …
    /// — has no `-- <extra-args>` tail and must not get the hint.
    func testDownstreamForUnknownCommands() {
        for cmd in ["list", "state", "path", "new", "exec", "logs", "version", ""] {
            XCTAssertNil(
                XcodebuildPassthroughHint.downstream(forCommand: cmd),
                "'\(cmd)' should have no downstream"
            )
        }
    }

    // MARK: - #89: generic unknown-option hint

    /// The motivating case from the issue body: user invents `--extra`
    /// on `vch test`, AP rejects it with bare "Unknown option", we
    /// nudge them at the `-- -extra <value>` shape.
    func testGenericUnknownOptionFiresOnInventedFlag() {
        let errorMessage = """
            Error: Unknown option '--extra'
            Usage: vch test [<options>] <name> -- [<extra-args> ...]
              See 'vch test --help' for more information.
            """
        let hint = XcodebuildPassthroughHint.genericUnknownOptionHint(
            command: "test",
            errorMessage: errorMessage,
            downstream: .xcodebuild
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("'--extra'"),
                      "hint should echo the rejected token: \(hint!)")
        XCTAssertTrue(hint!.contains("xcodebuild"),
                      "xcodebuild downstream should be named: \(hint!)")
        XCTAssertTrue(hint!.contains("-- -extra <value>"),
                      "hint should show the canonical pass-through form: \(hint!)")
        XCTAssertTrue(hint!.contains("vch test"),
                      "hint should name the user's actual subcommand: \(hint!)")
    }

    /// `vch run`'s `-- <args>` tail is forwarded to `simctl launch`,
    /// not xcodebuild. The wording must match — pointing the user at
    /// xcodebuild for a run-time arg would actively mislead.
    func testGenericUnknownOptionRunMentionsLaunchedApp() {
        let errorMessage = "Error: Unknown option '--extra'\nUsage: vch run …"
        let hint = XcodebuildPassthroughHint.genericUnknownOptionHint(
            command: "run",
            errorMessage: errorMessage,
            downstream: .appLaunchArgs
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("launched app"),
                      "appLaunchArgs downstream should be named: \(hint!)")
        XCTAssertFalse(hint!.contains("xcodebuild"),
                       "run hint must not mention xcodebuild: \(hint!)")
        XCTAssertTrue(hint!.contains("vch run"),
                      "hint should name the user's actual subcommand: \(hint!)")
    }

    /// Single-dash unknown options (e.g. `-flag`) should also get the
    /// generic hint; the canonicalized form drops one dash, so a
    /// `-flag` token round-trips as itself in the suggestion.
    func testGenericUnknownOptionSingleDashTokenIsPreserved() {
        let errorMessage = "Error: Unknown option '-flag'"
        let hint = XcodebuildPassthroughHint.genericUnknownOptionHint(
            command: "build",
            errorMessage: errorMessage,
            downstream: .xcodebuild
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("'-flag'"))
        XCTAssertTrue(hint!.contains("-- -flag <value>"))
    }

    // MARK: - #89: generic hint — negative cases

    /// AP's typo correction is a higher-signal diagnostic than our
    /// generic nudge. Deferring to it avoids stacking two
    /// contradictory suggestions on the same error.
    func testGenericUnknownOptionSkipsWhenDidYouMeanPresent() {
        let errorMessage = """
            Error: Unknown option '--schem'. Did you mean '--scheme'?
            Usage: vch test [<options>] <name> -- [<extra-args> ...]
            """
        XCTAssertNil(
            XcodebuildPassthroughHint.genericUnknownOptionHint(
                command: "test",
                errorMessage: errorMessage,
                downstream: .xcodebuild
            )
        )
    }

    /// Non-"Unknown option" validation failures (missing arg, missing
    /// value, value out of range, …) are a different problem — the
    /// pass-through nudge would be off-topic.
    func testGenericUnknownOptionSkipsForOtherValidationFailures() {
        let cases = [
            "Error: Missing expected argument '<name>'",
            "Error: Missing value for '--scheme <scheme>'",
            "Error: The value 'maybe' is invalid for '--no-sim'",
            "Some completely unrelated message",
        ]
        for msg in cases {
            XCTAssertNil(
                XcodebuildPassthroughHint.genericUnknownOptionHint(
                    command: "test",
                    errorMessage: msg,
                    downstream: .xcodebuild
                ),
                "should not fire for: \(msg)"
            )
        }
    }

    /// Defensive: if AP ever changes the error message format and
    /// the extracted token doesn't look like a flag, return nil
    /// instead of generating a nonsense hint.
    func testGenericUnknownOptionSkipsWhenTokenIsNotFlagShape() {
        let errorMessage = "Error: Unknown option 'no-dashes-here'"
        XCTAssertNil(
            XcodebuildPassthroughHint.genericUnknownOptionHint(
                command: "test",
                errorMessage: errorMessage,
                downstream: .xcodebuild
            )
        )
    }
}
