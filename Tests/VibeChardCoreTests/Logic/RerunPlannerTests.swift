import XCTest
@testable import VibeChardCore

/// `RerunPlanner` is the pure decision-tree behind `vch test
/// --rerun-failed` (#46): given the prior xcodebuild extra args and
/// the failed-test identifiers from the most recent run, produce the
/// new argv that re-runs only those failures while preserving every
/// other prior switch.
final class RerunPlannerTests: XCTestCase {

    func testEmptyPriorAndOneFailureProducesSingleSelector() {
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: [],
            failureIdentifiers: ["MyTests/SuiteA/testFoo()"]
        )
        XCTAssertEqual(out, ["-only-testing:MyTests/SuiteA/testFoo()"])
    }

    func testMultipleFailuresAreEachAppendedAsSeparateSelectors() {
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: [],
            failureIdentifiers: ["T/A/test1", "T/A/test2", "T/B/test3"]
        )
        XCTAssertEqual(out, [
            "-only-testing:T/A/test1",
            "-only-testing:T/A/test2",
            "-only-testing:T/B/test3"
        ])
    }

    func testKeepsUnrelatedPriorArgsAhead() {
        // -parallel-testing-enabled and -test-iterations are
        // orthogonal to test selection — they must be carried over
        // so the rerun reproduces the same execution shape.
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: [
                "-parallel-testing-enabled", "NO",
                "-test-iterations", "3"
            ],
            failureIdentifiers: ["T/A/test1"]
        )
        XCTAssertEqual(out, [
            "-parallel-testing-enabled", "NO",
            "-test-iterations", "3",
            "-only-testing:T/A/test1"
        ])
    }

    func testStripsPriorOnlyTestingColonForm() {
        // The whole point of --rerun-failed is to *narrow* selection;
        // a previous `-only-testing:Suite/A` must be dropped before
        // the failure-derived selectors are appended.
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: ["-only-testing:T/Old", "-parallel-testing-enabled", "NO"],
            failureIdentifiers: ["T/New/test"]
        )
        XCTAssertEqual(out, [
            "-parallel-testing-enabled", "NO",
            "-only-testing:T/New/test"
        ])
    }

    func testStripsPriorSkipTestingColonForm() {
        // -skip-testing: is the inverse selector. It MUST also be
        // dropped — keeping `-skip-testing:T/Foo` next to a fresh
        // `-only-testing:T/Foo` (where T/Foo is the failed test) would
        // have xcodebuild silently skip the rerun.
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: ["-skip-testing:T/Foo"],
            failureIdentifiers: ["T/Foo/testA"]
        )
        XCTAssertEqual(out, ["-only-testing:T/Foo/testA"])
    }

    func testStripsPriorOnlyTestingSpaceForm() {
        // Rare but valid: xcodebuild also accepts the
        // space-separated `-only-testing TestId` form. We must drop
        // both argv slots, not just the first.
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: ["-only-testing", "T/Old", "-parallel-testing-enabled", "NO"],
            failureIdentifiers: ["T/New/testA"]
        )
        XCTAssertEqual(out, [
            "-parallel-testing-enabled", "NO",
            "-only-testing:T/New/testA"
        ])
    }

    func testStripsPriorSkipTestingSpaceForm() {
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: ["-skip-testing", "T/Foo", "-quiet"],
            failureIdentifiers: ["T/Foo/testA"]
        )
        XCTAssertEqual(out, ["-quiet", "-only-testing:T/Foo/testA"])
    }

    func testTrailingDanglingBareSelectorDoesNotCrash() {
        // Defensive: a malformed prior list that ends with bare
        // `-only-testing` (no value) should not crash the planner.
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: ["-only-testing"],
            failureIdentifiers: ["T/A/testA"]
        )
        XCTAssertEqual(out, ["-only-testing:T/A/testA"])
    }

    func testDuplicateFailureIdentifiersAreDeduped() {
        // xcresult occasionally records the same test twice when a
        // retry-on-failure trait kicks in. Don't bloat argv with
        // duplicate selectors.
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: [],
            failureIdentifiers: ["T/A/testA", "T/A/testA", "T/A/testB"]
        )
        XCTAssertEqual(out, [
            "-only-testing:T/A/testA",
            "-only-testing:T/A/testB"
        ])
    }

    func testEmptyFailureIdentifiersJustStripsSelectors() {
        // The CLI is responsible for raising
        // `VibeChardError.testNoPriorFailures` before calling this
        // function with an empty failure list, but the function
        // itself stays total.
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: ["-only-testing:T/Old", "-quiet"],
            failureIdentifiers: []
        )
        XCTAssertEqual(out, ["-quiet"])
    }

    func testPreservesOrderOfRetainedPriorArgs() {
        // Don't reshuffle the user's flags — `-foo bar -baz qux`
        // must come back out in the same order.
        let out = RerunPlanner.extraArgsForRerunFailed(
            prior: ["-foo", "bar", "-baz", "qux"],
            failureIdentifiers: ["T/A/test1"]
        )
        XCTAssertEqual(out, [
            "-foo", "bar", "-baz", "qux",
            "-only-testing:T/A/test1"
        ])
    }

    // MARK: - normalizeIdentifier (#64)

    func testNormalizeIdentifierPrependsTargetWhenMissing() {
        // The bug: xcresulttool emits `Suite/Case()` (two segments)
        // for swift-testing under some Xcode 16 setups, but
        // `xcodebuild -only-testing:` requires
        // `Target/Suite/Case()`. The repair must restore the prefix.
        let out = RerunPlanner.normalizeIdentifier(
            "CloudSyncStatusCenterGraceTests/persistsAcrossRestart()",
            targetName: "BeanLedgerTests"
        )
        XCTAssertEqual(
            out,
            "BeanLedgerTests/CloudSyncStatusCenterGraceTests/persistsAcrossRestart()"
        )
    }

    func testNormalizeIdentifierLeavesProperlyPrefixedAlone() {
        // Already three-segment with the matching target — must not
        // double-prefix.
        let out = RerunPlanner.normalizeIdentifier(
            "BeanLedgerTests/Suite/case()",
            targetName: "BeanLedgerTests"
        )
        XCTAssertEqual(out, "BeanLedgerTests/Suite/case()")
    }

    func testNormalizeIdentifierLeavesXCTestSelectorAlone() {
        // XCTest pattern: `Target/ClassName/testMethod`. First
        // segment matches the target, leave alone.
        let out = RerunPlanner.normalizeIdentifier(
            "MyAppTests/MyClassTests/testFoo",
            targetName: "MyAppTests"
        )
        XCTAssertEqual(out, "MyAppTests/MyClassTests/testFoo")
    }

    func testNormalizeIdentifierPrependsWhenFirstSegmentDiffers() {
        // Defensive: the rule is "first segment must match the
        // target name exactly, otherwise prepend". The case where
        // xcresulttool hands us a three-segment id whose first
        // segment isn't `targetName` shouldn't happen in practice
        // (each failure JSON entry carries its own `targetName`),
        // but if it does we still prepend rather than guessing
        // — better to fail noisily on a malformed `-only-testing:`
        // arg than to silently drop the failure from the rerun.
        let out = RerunPlanner.normalizeIdentifier(
            "OtherTarget/Suite/case()",
            targetName: "MyTargetTests"
        )
        XCTAssertEqual(out, "MyTargetTests/OtherTarget/Suite/case()")
    }

    func testNormalizeIdentifierEmptyRawReturnsRaw() {
        XCTAssertEqual(
            RerunPlanner.normalizeIdentifier("", targetName: "T"),
            ""
        )
    }

    func testNormalizeIdentifierEmptyTargetReturnsRaw() {
        // Without a known target name there's nothing to repair
        // with — pass through verbatim.
        XCTAssertEqual(
            RerunPlanner.normalizeIdentifier("Suite/case()", targetName: ""),
            "Suite/case()"
        )
    }
}
