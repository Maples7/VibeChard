import Foundation

/// Decoded view of `xcrun xcresulttool get test-results summary` JSON
/// output, narrowed to the fields vch's test summary renderer cares
/// about.
///
/// **Why this exists** (#45). The streaming `TestOutputSummarizer` only
/// recognizes XCTest output (`Test Suite '...' started`,
/// `Test Case '-[Module.Suite test]' passed (...)`, etc). Targets that
/// use the swift-testing framework (`@Suite`, `@Test`, `#expect`) emit
/// an entirely different emoji-prefixed protocol that the streaming
/// parser ignores, so the final summary line reports `0 passed in ?`
/// even when many cases actually passed.
///
/// xcresult, in contrast, is the unified result format Apple writes
/// for both XCTest and swift-testing. Parsing it directly removes the
/// dependency on stdout text matching and gives us a correct count for
/// either framework — which is exactly what the bug needs.
///
/// The parser is intentionally tolerant: unknown / missing fields fall
/// back to defaults rather than throwing, since the JSON schema
/// evolves with each Xcode release. The streaming parser stays in
/// place as a fallback for the case where xcresult is missing
/// entirely (e.g. the build phase failed before xcodebuild produced a
/// bundle).
public struct XcresultSummary: Equatable, Sendable {

    public enum Status: String, Sendable {
        case succeeded
        case failed
        case unknown
    }

    public struct Failure: Equatable, Sendable {
        /// Display label for the suite that owns this failure. Inferred
        /// from `testIdentifierString` when possible, otherwise falls
        /// back to `targetName`.
        public let suite: String
        /// `testName` from the JSON. swift-testing returns the
        /// `@Test` display name (often quoted). XCTest returns the
        /// method selector.
        public let testCase: String
        /// `failureText` from the JSON, verbatim. May be multi-line.
        public let message: String
        /// Stable identifier xcodebuild accepts back as
        /// `-only-testing:<id>`. Reused by `vch test --rerun-failed`
        /// (#46). nil only when the JSON omits it (very old
        /// xcresulttool).
        public let testIdentifier: String?

        public init(
            suite: String,
            testCase: String,
            message: String,
            testIdentifier: String?
        ) {
            self.suite = suite
            self.testCase = testCase
            self.message = message
            self.testIdentifier = testIdentifier
        }
    }

    public let status: Status
    public let totalPassed: Int
    public let totalFailed: Int
    public let totalSkipped: Int
    public let expectedFailures: Int
    /// `finishTime - startTime`, in seconds. nil when the JSON is
    /// missing one of the timestamps.
    public let totalDurationSeconds: Double?
    public let failures: [Failure]

    public init(
        status: Status,
        totalPassed: Int,
        totalFailed: Int,
        totalSkipped: Int,
        expectedFailures: Int,
        totalDurationSeconds: Double?,
        failures: [Failure]
    ) {
        self.status = status
        self.totalPassed = totalPassed
        self.totalFailed = totalFailed
        self.totalSkipped = totalSkipped
        self.expectedFailures = expectedFailures
        self.totalDurationSeconds = totalDurationSeconds
        self.failures = failures
    }

    /// Parse a `xcrun xcresulttool get test-results summary` JSON
    /// blob. Returns nil only when the input is not a JSON object —
    /// every other deviation degrades to a default. The CLI treats a
    /// throw / nil here as "fall back to streaming parser".
    public static func parse(_ data: Data) throws -> XcresultSummary {
        let object: [String: Any]
        do {
            guard let any = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VibeChardError.externalCommandFailed(
                    cmd: "xcrun xcresulttool get test-results summary",
                    exitCode: -1,
                    stderr: "xcresulttool output is not a JSON object"
                )
            }
            object = any
        } catch let e as VibeChardError {
            throw e
        } catch {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun xcresulttool get test-results summary",
                exitCode: -1,
                stderr: "could not decode xcresulttool JSON: \(error)"
            )
        }

        // `result` is one of "Passed" / "Failed" / "Skipped" /
        // "Expected Failure" / "unknown". Treat skipped-only runs as
        // succeeded — xcodebuild itself returns 0 in that case, so
        // matching its semantics keeps the summary line consistent
        // with the exit code.
        let resultStr = object["result"] as? String ?? "unknown"
        let status: Status
        switch resultStr {
        case "Passed", "Expected Failure", "Skipped":
            status = .succeeded
        case "Failed":
            status = .failed
        default:
            status = .unknown
        }

        let passed = (object["passedTests"] as? Int) ?? 0
        let failed = (object["failedTests"] as? Int) ?? 0
        let skipped = (object["skippedTests"] as? Int) ?? 0
        let expected = (object["expectedFailures"] as? Int) ?? 0

        // `startTime` / `finishTime` are unix timestamps (seconds).
        let start = object["startTime"] as? Double
        let finish = object["finishTime"] as? Double
        let duration: Double?
        if let s = start, let f = finish, f >= s {
            duration = f - s
        } else {
            duration = nil
        }

        // The published JSON Schema declares `testFailures` as a
        // `$ref` to a single `TestFailure` object, but real output
        // emits an array (one entry per failure). Defensively accept
        // either shape.
        var failures: [Failure] = []
        if let arr = object["testFailures"] as? [[String: Any]] {
            for item in arr {
                if let f = parseFailure(item) { failures.append(f) }
            }
        } else if let single = object["testFailures"] as? [String: Any] {
            if let f = parseFailure(single) { failures.append(f) }
        }

        return XcresultSummary(
            status: status,
            totalPassed: passed,
            totalFailed: failed,
            totalSkipped: skipped,
            expectedFailures: expected,
            totalDurationSeconds: duration,
            failures: failures
        )
    }

    private static func parseFailure(_ obj: [String: Any]) -> Failure? {
        let target = (obj["targetName"] as? String) ?? ""
        let testName = (obj["testName"] as? String) ?? ""
        let failureText = (obj["failureText"] as? String) ?? ""
        let identifier = obj["testIdentifierString"] as? String

        if testName.isEmpty && target.isEmpty && failureText.isEmpty {
            return nil
        }

        let suiteLabel = inferSuiteLabel(targetName: target, testIdentifier: identifier) ?? target
        return Failure(
            suite: suiteLabel,
            testCase: testName,
            message: failureText,
            testIdentifier: identifier
        )
    }

    /// Pick a "suite" label from `testIdentifierString`. Observed
    /// shapes:
    ///   • `TargetName/SuiteName/testCase()` — swift-testing
    ///   • `TargetName/SuiteName/testCase`   — XCTest
    /// Falls back to `nil` when the identifier doesn't carry a
    /// suite-shaped middle segment, leaving the renderer to use
    /// `targetName`.
    private static func inferSuiteLabel(targetName: String, testIdentifier: String?) -> String? {
        guard let id = testIdentifier else { return nil }
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        // Strip the leading target if it matches.
        let suiteIndex = parts.first == targetName ? 1 : 0
        guard suiteIndex < parts.count - 1 else {
            // identifier had no "/" past the target — can't infer.
            return nil
        }
        return parts[suiteIndex]
    }
}
