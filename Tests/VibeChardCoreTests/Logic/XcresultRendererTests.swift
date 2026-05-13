import XCTest
@testable import VibeChardCore

/// Renderer coverage for the xcresult fallback path (#45). Mirrors the
/// shape of `TestOutputSummarizerTests.testRenderConcise*` so the
/// human-facing format stays consistent across the two summary
/// sources.
final class XcresultRendererTests: XCTestCase {

    private func makeSummary(
        status: XcresultSummary.Status,
        passed: Int,
        failed: Int,
        durationSeconds: Double? = 1.234,
        failures: [XcresultSummary.Failure] = []
    ) -> XcresultSummary {
        XcresultSummary(
            status: status,
            totalPassed: passed,
            totalFailed: failed,
            totalSkipped: 0,
            expectedFailures: 0,
            totalDurationSeconds: durationSeconds,
            failures: failures
        )
    }

    func testRendersSucceededWithCount() {
        let s = makeSummary(status: .succeeded, passed: 40, failed: 0)
        let out = XcresultRenderer.render(s, colorize: false)
        XCTAssertTrue(out.contains("✓ 40 passed in 1.23s"),
                      "swift-testing summary line must show real count, not 0")
        XCTAssertTrue(out.contains("** TEST SUCCEEDED **"))
    }

    func testRendersFailureBlock() {
        let s = makeSummary(
            status: .failed, passed: 2, failed: 1,
            failures: [
                .init(
                    suite: "MoneyTradeModelTests",
                    testCase: "testFinalBaseAmountFastPath()",
                    message: "Expectation failed: amount == 100; was 50",
                    testIdentifier: "BeanLedgerTests/MoneyTradeModelTests/testFinalBaseAmountFastPath()"
                )
            ]
        )
        let out = XcresultRenderer.render(s, colorize: false)
        XCTAssertTrue(out.contains("✗ MoneyTradeModelTests/testFinalBaseAmountFastPath()"))
        XCTAssertTrue(out.contains("Expectation failed"))
        XCTAssertTrue(out.contains("✗ 1 failed, 2 passed in 1.23s"))
        XCTAssertTrue(out.contains("** TEST FAILED **"))
    }

    func testUnknownStatusRendersWithoutCounts() {
        let s = makeSummary(status: .unknown, passed: 0, failed: 0,
                            durationSeconds: nil)
        let out = XcresultRenderer.render(s, colorize: false)
        XCTAssertTrue(out.contains("? test status unknown"))
    }

    func testUnknownStatusAppendsLogPathHint() {
        // #69: when xcodebuild dies before producing a parseable
        // xcresult, the launch banner's `→ log:` line has scrolled
        // off; the trailing summary needs to repeat the path so the
        // user can copy-paste it.
        let s = makeSummary(status: .unknown, passed: 0, failed: 0,
                            durationSeconds: nil)
        let out = XcresultRenderer.render(s, colorize: false,
                                          logPath: "/tmp/x/.vch/last-test.log")
        XCTAssertTrue(out.contains("? test status unknown"))
        XCTAssertTrue(out.contains("→ log: /tmp/x/.vch/last-test.log"),
                      "unknown branch must surface the log path; got: \(out)")
    }

    func testKnownStatusAppendsArtifactPathHints() {
        let s = makeSummary(status: .succeeded, passed: 1, failed: 0)
        let out = XcresultRenderer.render(s, colorize: false,
                                          logPath: "/tmp/x/.vch/last-test.log",
                                          resultBundlePath: "/tmp/x/.agent-build/Result.xcresult")
        XCTAssertTrue(out.contains("→ log: /tmp/x/.vch/last-test.log"),
                      "known-status xcresult summaries should surface the full log path; got: \(out)")
        XCTAssertTrue(out.contains("→ result: /tmp/x/.agent-build/Result.xcresult"),
                      "xcresult summaries should surface the result bundle path; got: \(out)")
    }

    func testNoColorWhenDisabled() {
        let s = makeSummary(status: .succeeded, passed: 1, failed: 0)
        let out = XcresultRenderer.render(s, colorize: false)
        XCTAssertFalse(out.contains("\u{1B}["),
                       "no ANSI escapes should leak when colorize=false")
    }

    func testColorWhenEnabled() {
        let s = makeSummary(status: .succeeded, passed: 1, failed: 0)
        let out = XcresultRenderer.render(s, colorize: true)
        XCTAssertTrue(out.contains("\u{1B}["),
                      "colorize=true should produce ANSI-styled head")
    }

    func testMultilineFailureMessageIndents() {
        let s = makeSummary(
            status: .failed, passed: 0, failed: 1,
            failures: [
                .init(
                    suite: "FooSuite",
                    testCase: "testBar",
                    message: "first line\nsecond line",
                    testIdentifier: nil
                )
            ]
        )
        let out = XcresultRenderer.render(s, colorize: false)
        XCTAssertTrue(out.contains("    first line"))
        XCTAssertTrue(out.contains("    second line"))
    }

    func testDurationBucketsAtMinuteBoundary() {
        // Same duration formatter contract as TestOutputSummarizer —
        // sub-minute uses two-decimal seconds, ≥ 60s switches to `Mm SSs`.
        let short = makeSummary(status: .succeeded, passed: 1, failed: 0,
                                durationSeconds: 12.4)
        XCTAssertTrue(XcresultRenderer.render(short, colorize: false).contains("12.40s"))

        let long = makeSummary(status: .succeeded, passed: 1, failed: 0,
                               durationSeconds: 75)
        XCTAssertTrue(XcresultRenderer.render(long, colorize: false).contains("1m 15s"))
    }
}
