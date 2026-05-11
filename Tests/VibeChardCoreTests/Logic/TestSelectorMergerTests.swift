import XCTest
@testable import VibeChardCore

final class TestSelectorMergerTests: XCTestCase {

    // MARK: - Empty input

    func testAllEmptyReturnsEmpty() {
        XCTAssertEqual(
            TestSelectorMerger.extraArgs(only: [], skip: [], extra: []),
            []
        )
    }

    // MARK: - Only selectors

    func testSingleOnlyTesting() {
        XCTAssertEqual(
            TestSelectorMerger.extraArgs(
                only: ["MyAppTests/MyClass"],
                skip: [],
                extra: []
            ),
            ["-only-testing:MyAppTests/MyClass"]
        )
    }

    func testRepeatableOnlyTesting() {
        XCTAssertEqual(
            TestSelectorMerger.extraArgs(
                only: ["MyAppTests/A", "MyAppTests/B/case()"],
                skip: [],
                extra: []
            ),
            [
                "-only-testing:MyAppTests/A",
                "-only-testing:MyAppTests/B/case()",
            ]
        )
    }

    // MARK: - Skip selectors

    func testRepeatableSkipTesting() {
        XCTAssertEqual(
            TestSelectorMerger.extraArgs(
                only: [],
                skip: ["MyAppTests/SlowSuite", "MyAppTests/Flaky"],
                extra: []
            ),
            [
                "-skip-testing:MyAppTests/SlowSuite",
                "-skip-testing:MyAppTests/Flaky",
            ]
        )
    }

    // MARK: - Mixed

    func testOnlyAndSkipCombined() {
        XCTAssertEqual(
            TestSelectorMerger.extraArgs(
                only: ["MyAppTests/A"],
                skip: ["MyAppTests/SlowSuite"],
                extra: []
            ),
            [
                "-only-testing:MyAppTests/A",
                "-skip-testing:MyAppTests/SlowSuite",
            ]
        )
    }

    func testExtraArgsAppendedAfterSelectors() {
        XCTAssertEqual(
            TestSelectorMerger.extraArgs(
                only: ["MyAppTests/A"],
                skip: ["MyAppTests/SlowSuite"],
                extra: ["-parallel-testing-enabled", "NO"]
            ),
            [
                "-only-testing:MyAppTests/A",
                "-skip-testing:MyAppTests/SlowSuite",
                "-parallel-testing-enabled",
                "NO",
            ]
        )
    }

    // MARK: - Edge cases

    /// Identifiers containing the Swift Testing `()` suffix should
    /// round-trip without escaping — xcodebuild handles the colon
    /// form natively.
    func testSwiftTestingFunctionIdentifier() {
        XCTAssertEqual(
            TestSelectorMerger.extraArgs(
                only: ["MyAppTests/MyClass/myFunc()"],
                skip: [],
                extra: []
            ),
            ["-only-testing:MyAppTests/MyClass/myFunc()"]
        )
    }

    /// Stable ordering guarantee documented in the helper: `only`
    /// first, then `skip`, then `extra`. Locked down so callers can
    /// log/diff the constructed argv predictably.
    func testStableOrdering() {
        let out = TestSelectorMerger.extraArgs(
            only: ["A1", "A2"],
            skip: ["S1"],
            extra: ["X1", "X2"]
        )
        XCTAssertEqual(
            out,
            [
                "-only-testing:A1",
                "-only-testing:A2",
                "-skip-testing:S1",
                "X1",
                "X2",
            ]
        )
    }
}
