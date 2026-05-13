import XCTest
@testable import VibeChardCore

final class TestOutputSummarizerTests: XCTestCase {

    // MARK: - Helpers

    private func feed(_ s: TestOutputSummarizer, _ block: String) {
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            s.feed(String(line))
        }
    }

    // MARK: - Happy paths

    func testParsesSinglePassingSuite() {
        let log = """
        Test Suite 'All tests' started at 2026-05-07 18:30:00.001
        Test Suite 'BeanLedgerTests.xctest' started at 2026-05-07 18:30:00.002
        Test Suite 'AccountsSnapshotTests' started at 2026-05-07 18:30:00.003
        Test Case '-[BeanLedgerTests.AccountsSnapshotTests testFoo]' started.
        Test Case '-[BeanLedgerTests.AccountsSnapshotTests testFoo]' passed (0.012 seconds).
        Test Case '-[BeanLedgerTests.AccountsSnapshotTests testBar]' started.
        Test Case '-[BeanLedgerTests.AccountsSnapshotTests testBar]' passed (0.008 seconds).
        Test Suite 'AccountsSnapshotTests' passed at 2026-05-07 18:30:00.024.
        \t Executed 2 tests, with 0 failures (0 unexpected) in 0.020 (0.021) seconds
        Test Suite 'BeanLedgerTests.xctest' passed at 2026-05-07 18:30:00.025.
        \t Executed 2 tests, with 0 failures (0 unexpected) in 0.020 (0.022) seconds
        Test Suite 'All tests' passed at 2026-05-07 18:30:00.026.
        \t Executed 2 tests, with 0 failures (0 unexpected) in 0.020 (0.025) seconds
        ** TEST SUCCEEDED **
        """

        let s = TestOutputSummarizer()
        feed(s, log)

        XCTAssertEqual(s.status, .succeeded)
        XCTAssertEqual(s.totalPassed, 2)
        XCTAssertEqual(s.totalFailed, 0)
        XCTAssertEqual(s.suites.count, 1, "Wrapping bundle + 'All tests' suites should be filtered out — only the leaf with test cases survives.")
        XCTAssertEqual(s.suites.first?.name, "AccountsSnapshotTests")
        XCTAssertEqual(s.suites.first?.passed, 2)
        XCTAssertEqual(s.suites.first?.failed, 0)
        XCTAssertEqual(s.totalDurationSeconds ?? -1, 0.025, accuracy: 0.0001)
        XCTAssertTrue(s.failures.isEmpty)
    }

    func testParsesFailureWithAssertionMessageAndFileLine() {
        let log = """
        Test Suite 'All tests' started at 2026-05-07 18:30:00.001
        Test Suite 'BeanLedgerTests.xctest' started at 2026-05-07 18:30:00.002
        Test Suite 'MoneyTradeModelTests' started at 2026-05-07 18:30:00.003
        Test Case '-[BeanLedgerTests.MoneyTradeModelTests testFinalBaseAmountFastPath]' started.
        /Users/me/repo/Tests/MoneyTradeModelTests.swift:97: error: -[BeanLedgerTests.MoneyTradeModelTests testFinalBaseAmountFastPath] : XCTAssertEqual failed: ("100") is not equal to ("50")
        Test Case '-[BeanLedgerTests.MoneyTradeModelTests testFinalBaseAmountFastPath]' failed (0.005 seconds).
        Test Case '-[BeanLedgerTests.MoneyTradeModelTests testOther]' started.
        Test Case '-[BeanLedgerTests.MoneyTradeModelTests testOther]' passed (0.001 seconds).
        Test Suite 'MoneyTradeModelTests' failed at 2026-05-07 18:30:00.012.
        \t Executed 2 tests, with 1 failure (0 unexpected) in 0.006 (0.009) seconds
        Test Suite 'BeanLedgerTests.xctest' failed at 2026-05-07 18:30:00.013.
        \t Executed 2 tests, with 1 failure (0 unexpected) in 0.006 (0.011) seconds
        Test Suite 'All tests' failed at 2026-05-07 18:30:00.014.
        \t Executed 2 tests, with 1 failure (0 unexpected) in 0.006 (0.013) seconds
        ** TEST FAILED **
        """

        let s = TestOutputSummarizer()
        feed(s, log)

        XCTAssertEqual(s.status, .failed)
        XCTAssertEqual(s.totalPassed, 1)
        XCTAssertEqual(s.totalFailed, 1)

        XCTAssertEqual(s.failures.count, 1)
        let f = s.failures[0]
        XCTAssertEqual(f.suite, "MoneyTradeModelTests")
        XCTAssertEqual(f.testCase, "testFinalBaseAmountFastPath")
        XCTAssertEqual(f.line, 97)
        XCTAssertEqual(f.file, "/Users/me/repo/Tests/MoneyTradeModelTests.swift")
        XCTAssertTrue(f.message.contains("XCTAssertEqual"))
    }

    func testParsesFailureWithLineColumn() {
        // Some Xcode versions emit `path:line:column: error: ...`.
        let log = """
        Test Suite 'All tests' started at 2026-05-07 18:30:00.001
        Test Suite 'FooBundle.xctest' started at 2026-05-07 18:30:00.001
        Test Suite 'FooTests' started at 2026-05-07 18:30:00.001
        Test Case '-[FooBundle.FooTests testQux]' started.
        /a/b/Foo.swift:42:9: error: -[FooBundle.FooTests testQux] : asserted false
        Test Case '-[FooBundle.FooTests testQux]' failed (0.001 seconds).
        Test Suite 'FooTests' failed at 2026-05-07 18:30:00.002.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        Test Suite 'FooBundle.xctest' failed at 2026-05-07 18:30:00.002.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        Test Suite 'All tests' failed at 2026-05-07 18:30:00.002.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        ** TEST FAILED **
        """

        let s = TestOutputSummarizer()
        feed(s, log)
        XCTAssertEqual(s.failures.count, 1)
        let f = s.failures[0]
        XCTAssertEqual(f.line, 42)
        XCTAssertEqual(f.file, "/a/b/Foo.swift")
    }

    func testFailedTestWithoutAssertionMessage() {
        // Crash inside a test produces a failed marker with no
        // preceding `error:` line. We must still record the failure.
        let log = """
        Test Suite 'All tests' started at 2026-05-07 18:30:00.001
        Test Suite 'CrashyBundle.xctest' started at 2026-05-07 18:30:00.001
        Test Suite 'CrashyTests' started at 2026-05-07 18:30:00.001
        Test Case '-[CrashyBundle.CrashyTests testCrash]' started.
        Test Case '-[CrashyBundle.CrashyTests testCrash]' failed (0.001 seconds).
        Test Suite 'CrashyTests' failed at 2026-05-07 18:30:00.002.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        Test Suite 'CrashyBundle.xctest' failed at 2026-05-07 18:30:00.002.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        Test Suite 'All tests' failed at 2026-05-07 18:30:00.002.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        ** TEST FAILED **
        """

        let s = TestOutputSummarizer()
        feed(s, log)
        XCTAssertEqual(s.failures.count, 1)
        XCTAssertTrue(s.failures[0].message.contains("no assertion message"))
    }

    func testMultipleSuitesMixedOutcomes() {
        let log = """
        Test Suite 'All tests' started at t
        Test Suite 'B.xctest' started at t
        Test Suite 'A' started at t
        Test Case '-[B.A test1]' started.
        Test Case '-[B.A test1]' passed (0.01 seconds).
        Test Case '-[B.A test2]' started.
        Test Case '-[B.A test2]' passed (0.01 seconds).
        Test Suite 'A' passed at t.
        \t Executed 2 tests, with 0 failures (0 unexpected) in 0.020 (0.020) seconds
        Test Suite 'C' started at t
        Test Case '-[B.C testX]' started.
        /x/X.swift:1: error: -[B.C testX] : nope
        Test Case '-[B.C testX]' failed (0.01 seconds).
        Test Suite 'C' failed at t.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.010 (0.011) seconds
        Test Suite 'B.xctest' failed at t.
        \t Executed 3 tests, with 1 failure (0 unexpected) in 0.030 (0.033) seconds
        Test Suite 'All tests' failed at t.
        \t Executed 3 tests, with 1 failure (0 unexpected) in 0.030 (0.040) seconds
        ** TEST FAILED **
        """

        let s = TestOutputSummarizer()
        feed(s, log)
        XCTAssertEqual(s.suites.map { $0.name }, ["A", "C"])
        XCTAssertEqual(s.suites[0].passed, 2)
        XCTAssertEqual(s.suites[1].failed, 1)
        XCTAssertEqual(s.totalPassed, 2)
        XCTAssertEqual(s.totalFailed, 1)
    }

    // MARK: - Sad paths

    func testEmptyLogStaysUnknown() {
        let s = TestOutputSummarizer()
        XCTAssertEqual(s.status, .unknown)
        XCTAssertTrue(s.suites.isEmpty)
        XCTAssertTrue(s.failures.isEmpty)
    }

    func testNoiseLinesAreIgnored() {
        let s = TestOutputSummarizer()
        feed(s, "Some random xcodebuild banner\n=== BUILD TARGET BeanLedger ===\n** BUILD SUCCEEDED **")
        XCTAssertEqual(s.status, .unknown)
        XCTAssertTrue(s.suites.isEmpty)
    }

    func testCompileFailureProducesUnknownStatus() {
        // xcodebuild bails out before any Test Suite line.
        let s = TestOutputSummarizer()
        feed(s, "/repo/Foo.swift:5:1: error: cannot find 'bar' in scope")
        XCTAssertEqual(s.status, .unknown)
        XCTAssertTrue(s.suites.isEmpty)
        // The "error:" line is not in `Test Case` form, so we don't
        // mistakenly record a failure for it.
        XCTAssertTrue(s.failures.isEmpty)
    }

    // MARK: - Render

    func testRenderSuccessLineHasMarker() {
        let s = TestOutputSummarizer()
        feed(s, """
        Test Suite 'All tests' started at t
        Test Suite 'B.xctest' started at t
        Test Suite 'A' started at t
        Test Case '-[B.A t1]' started.
        Test Case '-[B.A t1]' passed (0.01 seconds).
        Test Suite 'A' passed at t.
        \t Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.010) seconds
        Test Suite 'B.xctest' passed at t.
        \t Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.010) seconds
        Test Suite 'All tests' passed at t.
        \t Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
        ** TEST SUCCEEDED **
        """)
        let rendered = s.render(colorize: false)
        XCTAssertTrue(rendered.contains("✓ 1 passed"))
        XCTAssertTrue(rendered.contains("** TEST SUCCEEDED **"))
        XCTAssertTrue(rendered.contains("A"))
    }

    func testRenderFailureShowsFileLineAndMessage() {
        let s = TestOutputSummarizer()
        feed(s, """
        Test Suite 'All tests' started at t
        Test Suite 'B.xctest' started at t
        Test Suite 'F' started at t
        Test Case '-[B.F testNope]' started.
        /a/F.swift:13: error: -[B.F testNope] : XCTAssertEqual failed: ("a") is not equal to ("b")
        Test Case '-[B.F testNope]' failed (0.001 seconds).
        Test Suite 'F' failed at t.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        Test Suite 'B.xctest' failed at t.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        Test Suite 'All tests' failed at t.
        \t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds
        ** TEST FAILED **
        """)
        let rendered = s.render(colorize: false)
        // Acceptance: failing test summarized inline with file:line and assertion message.
        XCTAssertTrue(rendered.contains("✗ F/testNope"))
        XCTAssertTrue(rendered.contains("F.swift:13"))
        XCTAssertTrue(rendered.contains("XCTAssertEqual failed"))
        XCTAssertTrue(rendered.contains("** TEST FAILED **"))
        // Acceptance: parseable by `grep '✗ '`.
        XCTAssertTrue(rendered.split(separator: "\n").contains { $0.hasPrefix("✗ F/testNope") })
    }

    func testRenderUnknownStatusIsHonest() {
        let s = TestOutputSummarizer()
        let rendered = s.render(colorize: false)
        XCTAssertTrue(rendered.contains("unknown"))
    }

    func testRenderUnknownStatusAppendsLogPathHint() {
        // #69: when xcodebuild aborts before producing a parseable
        // result bundle, the "see full log" hint must point the user
        // at the file. Without the path it's hard to act on after the
        // launch banner has scrolled off.
        let s = TestOutputSummarizer()
        let rendered = s.render(colorize: false,
                                logPath: "/tmp/x/.vch/last-test.log")
        XCTAssertTrue(rendered.contains("? test status unknown"))
        XCTAssertTrue(rendered.contains("→ log: /tmp/x/.vch/last-test.log"),
                      "unknown branch must surface the log path; got: \(rendered)")
    }

    func testRenderKnownStatusAppendsArtifactPathHints() {
        let s = TestOutputSummarizer()
        feed(s, """
        Test Suite 'All tests' started at t
        Test Suite 'B.xctest' started at t
        Test Suite 'A' started at t
        Test Case '-[B.A t1]' started.
        Test Case '-[B.A t1]' passed (0.01 seconds).
        Test Suite 'A' passed at t.
        \t Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.010) seconds
        Test Suite 'B.xctest' passed at t.
        \t Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.010) seconds
        Test Suite 'All tests' passed at t.
        \t Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
        ** TEST SUCCEEDED **
        """)
        let rendered = s.render(colorize: false,
                                logPath: "/tmp/x/.vch/last-test.log",
                                resultBundlePath: "/tmp/x/.agent-build/Result.xcresult")
        XCTAssertTrue(rendered.contains("→ log: /tmp/x/.vch/last-test.log"),
                      "known-status test summaries should surface the full log path; got: \(rendered)")
        XCTAssertTrue(rendered.contains("→ result: /tmp/x/.agent-build/Result.xcresult"),
                      "test summaries should surface the result bundle path; got: \(rendered)")
    }
}
