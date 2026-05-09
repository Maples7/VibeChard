import XCTest
@testable import VibeChardCore

/// Coverage for the xcresult-driven side of #45 — the swift-testing
/// summary fix. The fixtures here are hand-crafted to match the JSON
/// schema documented by `xcrun xcresulttool get test-results summary
/// --schema` (Xcode 16+); see `Sources/VibeChardCore/Logic/
/// XcresultSummary.swift` for the rationale on why we trust this
/// format over stdout matching.
final class XcresultSummaryTests: XCTestCase {

    // MARK: - Helpers

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Happy path: swift-testing succeeded

    func testParsesSwiftTestingPassedRun() throws {
        // Counts and timestamps are what xcresulttool emits for a
        // 40-test swift-testing run. The streaming parser would have
        // returned `0 passed in ?` here — that's the bug #45 reports.
        let json = """
        {
            "title": "Test - BeanLedger",
            "startTime": 760000000.0,
            "finishTime": 760000006.2,
            "result": "Passed",
            "totalTestCount": 40,
            "passedTests": 40,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "environmentDescription": "iPhone 16 - iOS 18.5",
            "topInsights": [],
            "statistics": [],
            "devicesAndConfigurations": [],
            "testFailures": []
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertEqual(summary.totalPassed, 40)
        XCTAssertEqual(summary.totalFailed, 0)
        XCTAssertEqual(summary.totalSkipped, 0)
        XCTAssertEqual(summary.expectedFailures, 0)
        XCTAssertEqual(summary.totalDurationSeconds ?? -1, 6.2, accuracy: 0.01)
        XCTAssertTrue(summary.failures.isEmpty)
    }

    // MARK: - Happy path: failures with detail

    func testParsesFailureDetailFromArrayShape() throws {
        // Real-world xcresulttool output for a swift-testing target
        // with one failure. testIdentifierString is the
        // `-only-testing:` form #46 needs to round-trip --rerun-failed.
        let json = """
        {
            "title": "Test - BeanLedger",
            "startTime": 760000000.0,
            "finishTime": 760000005.5,
            "result": "Failed",
            "totalTestCount": 3,
            "passedTests": 2,
            "failedTests": 1,
            "skippedTests": 0,
            "expectedFailures": 0,
            "environmentDescription": "iPhone 16 - iOS 18.5",
            "topInsights": [],
            "statistics": [],
            "devicesAndConfigurations": [],
            "testFailures": [
                {
                    "testName": "testFinalBaseAmountFastPath()",
                    "targetName": "BeanLedgerTests",
                    "failureText": "Expectation failed: amount == 100; was 50",
                    "testIdentifier": 0,
                    "testIdentifierString": "BeanLedgerTests/MoneyTradeModelTests/testFinalBaseAmountFastPath()"
                }
            ]
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.totalPassed, 2)
        XCTAssertEqual(summary.totalFailed, 1)
        XCTAssertEqual(summary.failures.count, 1)
        let f = summary.failures[0]
        XCTAssertEqual(f.testCase, "testFinalBaseAmountFastPath()")
        XCTAssertEqual(f.suite, "MoneyTradeModelTests",
                       "suite label should be the middle segment of testIdentifierString, not the target")
        XCTAssertTrue(f.message.contains("Expectation failed"))
        XCTAssertEqual(f.testIdentifier,
                       "BeanLedgerTests/MoneyTradeModelTests/testFinalBaseAmountFastPath()")
    }

    func testParsesFailureFromSingleObjectShape() throws {
        // Apple's published JSON Schema declares `testFailures` as a
        // single `$ref` to TestFailure rather than an array. We accept
        // both because real output emits an array but the schema
        // implies an object form is also valid.
        let json = """
        {
            "title": "Test",
            "startTime": 760000000.0,
            "finishTime": 760000001.0,
            "result": "Failed",
            "totalTestCount": 1,
            "passedTests": 0,
            "failedTests": 1,
            "skippedTests": 0,
            "expectedFailures": 0,
            "environmentDescription": "x",
            "topInsights": [],
            "statistics": [],
            "devicesAndConfigurations": [],
            "testFailures": {
                "testName": "testFoo",
                "targetName": "FooTests",
                "failureText": "boom",
                "testIdentifier": 0,
                "testIdentifierString": "FooTests/FooSuite/testFoo"
            }
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures[0].testCase, "testFoo")
        XCTAssertEqual(summary.failures[0].suite, "FooSuite")
    }

    // MARK: - Status mapping

    func testSkippedOnlyRunsCountAsSucceeded() throws {
        // xcodebuild exits 0 when every test was skipped, and the
        // banner is `** TEST SUCCEEDED **`. We mirror that here so the
        // summary line stays consistent with the exit code.
        let json = """
        {
            "title": "Test", "startTime": 0, "finishTime": 1,
            "result": "Skipped",
            "totalTestCount": 1, "passedTests": 0, "failedTests": 0,
            "skippedTests": 1, "expectedFailures": 0,
            "environmentDescription": "x", "topInsights": [],
            "statistics": [], "devicesAndConfigurations": [],
            "testFailures": []
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertEqual(summary.totalSkipped, 1)
    }

    func testExpectedFailureIsTreatedAsSucceeded() throws {
        let json = """
        {
            "title": "Test", "startTime": 0, "finishTime": 1,
            "result": "Expected Failure",
            "totalTestCount": 1, "passedTests": 0, "failedTests": 0,
            "skippedTests": 0, "expectedFailures": 1,
            "environmentDescription": "x", "topInsights": [],
            "statistics": [], "devicesAndConfigurations": [],
            "testFailures": []
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertEqual(summary.expectedFailures, 1)
    }

    func testUnknownResultMapsToUnknown() throws {
        let json = """
        {
            "title": "Test", "startTime": 0, "finishTime": 1,
            "result": "unknown",
            "totalTestCount": 0, "passedTests": 0, "failedTests": 0,
            "skippedTests": 0, "expectedFailures": 0,
            "environmentDescription": "x", "topInsights": [],
            "statistics": [], "devicesAndConfigurations": [],
            "testFailures": []
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertEqual(summary.status, .unknown)
    }

    // MARK: - Tolerant decoding

    func testMissingTimestampsLeaveDurationNil() throws {
        let json = """
        {
            "title": "Test",
            "result": "Passed",
            "totalTestCount": 1, "passedTests": 1, "failedTests": 0,
            "skippedTests": 0, "expectedFailures": 0,
            "environmentDescription": "x", "topInsights": [],
            "statistics": [], "devicesAndConfigurations": [],
            "testFailures": []
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertNil(summary.totalDurationSeconds)
    }

    func testInvertedTimestampsLeaveDurationNil() throws {
        // Defensive — finish < start should not produce a negative
        // duration in the summary line.
        let json = """
        {
            "title": "Test",
            "startTime": 100.0, "finishTime": 50.0,
            "result": "Passed",
            "totalTestCount": 1, "passedTests": 1, "failedTests": 0,
            "skippedTests": 0, "expectedFailures": 0,
            "environmentDescription": "x", "topInsights": [],
            "statistics": [], "devicesAndConfigurations": [],
            "testFailures": []
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertNil(summary.totalDurationSeconds)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try XcresultSummary.parse(data("not json")))
    }

    func testNonObjectTopLevelThrows() {
        // xcresulttool always emits an object at the top level. A
        // bare array (or anything else) means we got the wrong file.
        XCTAssertThrowsError(try XcresultSummary.parse(data("[1, 2, 3]")))
    }

    // MARK: - Failure label inference

    func testFailureWithoutIdentifierFallsBackToTargetName() throws {
        // No testIdentifierString — older xcresulttool. We can't
        // infer the suite, so we display the target name.
        let json = """
        {
            "title": "Test", "startTime": 0, "finishTime": 1,
            "result": "Failed",
            "totalTestCount": 1, "passedTests": 0, "failedTests": 1,
            "skippedTests": 0, "expectedFailures": 0,
            "environmentDescription": "x", "topInsights": [],
            "statistics": [], "devicesAndConfigurations": [],
            "testFailures": [{
                "testName": "testFoo",
                "targetName": "FooTests",
                "failureText": "boom",
                "testIdentifier": 0
            }]
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertEqual(summary.failures[0].suite, "FooTests")
        XCTAssertNil(summary.failures[0].testIdentifier)
    }

    func testFailureWithEmptyShapeIsIgnored() throws {
        // Defensive: an empty failure object shouldn't leak through
        // as a phantom ✗ line.
        let json = """
        {
            "title": "Test", "startTime": 0, "finishTime": 1,
            "result": "Failed",
            "totalTestCount": 0, "passedTests": 0, "failedTests": 1,
            "skippedTests": 0, "expectedFailures": 0,
            "environmentDescription": "x", "topInsights": [],
            "statistics": [], "devicesAndConfigurations": [],
            "testFailures": [{}]
        }
        """
        let summary = try XcresultSummary.parse(data(json))
        XCTAssertTrue(summary.failures.isEmpty)
    }
}
