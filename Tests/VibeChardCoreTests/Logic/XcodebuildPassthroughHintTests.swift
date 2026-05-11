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
}
