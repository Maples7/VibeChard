import Foundation

/// Streaming parser for `xcodebuild test` output.
///
/// Feed every stdout/stderr line through `feed(_:)`, then call
/// `render(verbose:colorize:)` to obtain the concise summary the CLI
/// prints when `--verbose` is off.
///
/// **Scope**: XCTest only. Swift Testing's emoji-prefixed format
/// (`􀟈 Test run started.`) is captured into the log file but is not
/// summarized in this version. Issue #9 is intentionally scoped to
/// XCTest because that is what real iOS / macOS Apple-platform
/// projects use today; Swift Testing support can be added in a
/// follow-up without changing the public surface here.
///
/// The parser is intentionally tolerant: it does not throw on
/// unrecognized lines, never panics on malformed input, and degrades
/// gracefully to `Status.unknown` when xcodebuild prints output we
/// don't understand. The full firehose is always available in the
/// tee'd `last-test.log`.
public final class TestOutputSummarizer {

    public struct Suite: Equatable, Sendable {
        public let name: String
        public var passed: Int
        public var failed: Int
        public var durationSeconds: Double

        public init(name: String, passed: Int = 0, failed: Int = 0, durationSeconds: Double = 0) {
            self.name = name
            self.passed = passed
            self.failed = failed
            self.durationSeconds = durationSeconds
        }
    }

    public struct Failure: Equatable, Sendable {
        public let suite: String
        public let testCase: String
        public let file: String?
        public let line: Int?
        public let message: String

        public init(suite: String, testCase: String, file: String?, line: Int?, message: String) {
            self.suite = suite
            self.testCase = testCase
            self.file = file
            self.line = line
            self.message = message
        }
    }

    public enum Status: String, Sendable {
        case succeeded
        case failed
        case packageResolutionFailed
        case unknown
    }

    /// Final status. Set when we see `** TEST SUCCEEDED **` /
    /// `** TEST FAILED **`. Defaults to `.unknown` until then.
    public private(set) var status: Status = .unknown

    /// True once xcodebuild has moved beyond build/signing work and
    /// started executing tests. Useful for classifying idle hangs that
    /// happen after compilation has already succeeded.
    public private(set) var reachedTestExecution: Bool = false

    /// Wall-clock duration reported by xcodebuild for the *root*
    /// `'All tests'` suite. nil when xcodebuild bails out before that
    /// line (e.g. compile failure).
    public private(set) var totalDurationSeconds: Double?

    /// Leaf suites only (those that contained at least one test case
    /// directly, not via nesting). Stable in the order xcodebuild
    /// emitted them.
    public private(set) var suites: [Suite] = []

    /// All recorded failures, in source order.
    public private(set) var failures: [Failure] = []

    /// First top-level `xcodebuild: error:` line observed, when the
    /// run failed before XCTest emitted a normal test summary.
    public private(set) var firstXcodebuildErrorLine: String?

    public var totalPassed: Int { suites.reduce(0) { $0 + $1.passed } }
    public var totalFailed: Int { suites.reduce(0) { $0 + $1.failed } }

    public init() {}

    // MARK: - Streaming

    /// Feed one log line (no trailing newline). Safe to call from a
    /// single thread; do not feed concurrently.
    public func feed(_ rawLine: String) {
        let line = rawLine
        if line.contains("Testing started") {
            reachedTestExecution = true
            return
        }
        // Final status — check first so we don't waste time on regex.
        if line.contains("** TEST SUCCEEDED **") {
            status = .succeeded
            return
        }
        if line.contains("** TEST FAILED **") {
            status = .failed
            return
        }

        if line.contains("xcodebuild: error: Could not resolve package dependencies") {
            status = .packageResolutionFailed
            captureFirstXcodebuildError(line)
            return
        }

        if line.hasPrefix("xcodebuild: error:") {
            captureFirstXcodebuildError(line)
            return
        }

        // Suite open: `Test Suite 'X' started at ...`
        if let suiteName = match(line: line, pattern: Self.suiteStartedRegex, captureIndex: 1) {
            reachedTestExecution = true
            suiteStack.append(suiteName)
            return
        }
        // Suite close: `Test Suite 'X' (passed|failed) at ...`. We
        // *don't* commit the rollup here — the immediately-following
        // `Executed N tests, with K failures... in T (T) seconds` line
        // carries the duration. We just snapshot the close marker.
        if let _ = match(line: line, pattern: Self.suiteEndedRegex, captureIndex: 1) {
            pendingSuiteClose = true
            return
        }
        // Suite rollup: `\t Executed N tests, with K failures (...) in <internal> (<wall>) seconds`
        // (xcodebuild emits this both for leaf suites and for the
        // wrapping bundle / `'All tests'` suites). We pop the stack
        // here and only flush a leaf rollup when leafCounts contains
        // entries for the popped suite.
        if pendingSuiteClose,
           let m = matches(line: line, pattern: Self.suiteRollupRegex) {
            pendingSuiteClose = false
            // m has captures: total, failed, wall. We compute leaf
            // duration from the wall-clock value xcodebuild reports.
            let totalStr = m[1]
            let _ = totalStr // silence unused; we rely on per-test counting
            let wall = Double(m[3]) ?? 0
            // Pop the suite that just closed.
            if let popped = suiteStack.popLast() {
                if let counts = leafCounts.removeValue(forKey: popped) {
                    suites.append(Suite(
                        name: popped,
                        passed: counts.passed,
                        failed: counts.failed,
                        durationSeconds: wall
                    ))
                }
                // The very last `Executed` line (after `'All tests'`
                // closes and the stack is empty) gives us the run's
                // wall-clock duration.
                if suiteStack.isEmpty {
                    totalDurationSeconds = wall
                }
            }
            return
        }
        // Failure assertion: `path:line: error: -[Module.SuiteName methodName] : message`
        // (path may also include a column: `path:line:col: error: ...` — accept either.)
        if let f = parseFailureMessage(line) {
            // Buffer per testID; a single test may emit several
            // assertion lines. We flush on the test's `failed (...)` line.
            pendingFailures[f.testID, default: []].append(f)
            return
        }
        // Test case status: `Test Case '-[Module.SuiteName methodName]' (passed|failed) (T seconds).`
        if let t = parseTestCase(line) {
            // Attribute to the leaf suite we believe is on top. Some
            // xcodebuild versions use `Module.SuiteName` as the suite
            // name (e.g. `BeanLedgerTests.AccountsSnapshotTests`); we
            // strip the module prefix for display.
            let suiteName = t.suite
            if t.passed {
                leafCounts[suiteName, default: .zero].passed += 1
            } else {
                leafCounts[suiteName, default: .zero].failed += 1
                let id = "\(t.suite)/\(t.testCase)"
                let drained = pendingFailures.removeValue(forKey: id) ?? []
                if drained.isEmpty {
                    // Failed without any assertion line (e.g. crash).
                    failures.append(Failure(
                        suite: t.suite, testCase: t.testCase,
                        file: nil, line: nil, message: "(no assertion message captured)"
                    ))
                } else {
                    for raw in drained {
                        failures.append(Failure(
                            suite: t.suite, testCase: t.testCase,
                            file: raw.file, line: raw.lineNumber, message: raw.message
                        ))
                    }
                }
            }
            return
        }
        // Anything else: ignore. The full text is still in last-test.log.
    }

    // MARK: - Render

    /// Render the human-readable summary that `vch test` prints when
    /// `--verbose` is off. `colorize` controls ANSI styling and is
    /// resolved by the CLI per `ANSI.shouldColorize(...)`.
    ///
    /// `logPath` / `resultBundlePath` (#69/#93) are appended as
    /// compact trailing artifact lines when present, so the user can
    /// inspect the full firehose or xcresult without scrolling back
    /// to the launch banner.
    public func render(
        colorize: Bool,
        logPath: String? = nil,
        resultBundlePath: String? = nil
    ) -> String {
        var out: [String] = []
        // Failures first (so the user's eye lands on them).
        if !failures.isEmpty {
            for f in failures {
                let head = "✗ \(f.suite)/\(f.testCase)"
                out.append(ANSI.wrap(head, .fail, enabled: colorize))
                if let file = f.file {
                    let leaf = (file as NSString).lastPathComponent
                    if let ln = f.line {
                        out.append("    at \(leaf):\(ln)")
                    } else {
                        out.append("    at \(leaf)")
                    }
                }
                // Indent each message line with 4 spaces.
                for line in f.message.split(separator: "\n", omittingEmptySubsequences: false) {
                    out.append("    \(line)")
                }
                out.append("")
            }
        }
        // Suite rollups.
        if !suites.isEmpty {
            // Width of the longest suite name, capped at 40 to avoid
            // pathological alignment when someone has a giant suite name.
            let nameWidth = min(40, suites.map { $0.name.count }.max() ?? 0)
            for s in suites {
                let padded = s.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                let counts: String
                if s.failed > 0 {
                    counts = ANSI.wrap("\(s.failed) failed", .fail, enabled: colorize)
                        + ", \(s.passed) passed"
                } else {
                    counts = "\(s.passed) passed"
                }
                out.append("  \(padded)  \(counts) in \(formatDuration(s.durationSeconds))")
            }
            out.append("")
        }
        // Final tally.
        let total = totalPassed + totalFailed
        let durStr = totalDurationSeconds.map(formatDuration) ?? "?"
        let head: String
        switch status {
        case .succeeded:
            let line = "✓ \(total) passed in \(durStr)   ** TEST SUCCEEDED **"
            head = ANSI.wrap(line, .ok, enabled: colorize)
        case .failed where !reachedTestExecution:
            // #157: `xcodebuild test` failed during the build phase
            // (a compile / link error) before any test ran. Printing
            // `0 failed, 0 passed` here reads as "the suite ran and
            // found nothing", sending people hunting for a test filter
            // or empty-suite problem that doesn't exist. Name the
            // build phase as the culprit and say tests were skipped;
            // the compile diagnostics live in the tee'd log the
            // `→ log:` line below points at.
            let line = "✗ build failed — tests not run   ** BUILD FAILED **"
            head = ANSI.wrap(line, .fail, enabled: colorize)
        case .failed:
            let line = "✗ \(totalFailed) failed, \(totalPassed) passed in \(durStr)   ** TEST FAILED **"
            head = ANSI.wrap(line, .fail, enabled: colorize)
        case .packageResolutionFailed:
            head = ANSI.wrap("✗ package dependency resolution failed — see full log", .fail, enabled: colorize)
        case .unknown:
            // No `** TEST ... **` marker observed (e.g. compile error
            // or xcodebuild aborted mid-run). Don't fake a status —
            // tell the user where the firehose lives.
            head = "? test status unknown — see full log"
        }
        out.append(head)
        if case .packageResolutionFailed = status,
           let line = firstXcodebuildErrorLine {
            out.append("    \(line)")
        }
        if let path = logPath, !path.isEmpty {
            out.append("   → log: \(path)")
        }
        if let path = resultBundlePath, !path.isEmpty {
            out.append("   → result: \(path)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Internals

    private struct Counts: Equatable {
        var passed: Int
        var failed: Int
        static let zero = Counts(passed: 0, failed: 0)
    }

    private struct PendingFailure {
        let testID: String
        let file: String?
        let lineNumber: Int?
        let message: String
    }

    private var suiteStack: [String] = []
    private var pendingSuiteClose: Bool = false
    private var leafCounts: [String: Counts] = [:]
    private var pendingFailures: [String: [PendingFailure]] = [:]

    private func captureFirstXcodebuildError(_ line: String) {
        if firstXcodebuildErrorLine == nil {
            firstXcodebuildErrorLine = line
        }
    }

    // MARK: - Regex helpers (cached compiled NSRegularExpression instances)

    private static let suiteStartedRegex: NSRegularExpression = {
        // Test Suite 'AccountsSnapshotTests' started at 2026-...
        try! NSRegularExpression(pattern: "^Test Suite '([^']+)' started at ")
    }()

    private static let suiteEndedRegex: NSRegularExpression = {
        // Test Suite 'AccountsSnapshotTests' (passed|failed) at ...
        try! NSRegularExpression(pattern: "^Test Suite '([^']+)' (passed|failed) at ")
    }()

    private static let suiteRollupRegex: NSRegularExpression = {
        //          Executed 12 tests, with 1 failure (0 unexpected) in 0.123 (0.124) seconds
        // (failure / failures, leading whitespace tab-or-space)
        try! NSRegularExpression(pattern: "^\\s*Executed (\\d+) tests?, with (\\d+) failures? \\(\\d+ unexpected\\) in [0-9.]+ \\(([0-9.]+)\\) seconds")
    }()

    private static let testCaseRegex: NSRegularExpression = {
        // Test Case '-[Module.SuiteName testFoo]' passed (0.012 seconds).
        // Test Case '-[Module.SuiteName testFoo]' failed (0.005 seconds).
        try! NSRegularExpression(pattern: "^Test Case '-\\[([^ ]+) ([^\\]]+)\\]' (passed|failed) \\(([0-9.]+) seconds\\)\\.\\s*$")
    }()

    private static let failureMessageRegex: NSRegularExpression = {
        // /path/to/File.swift:42: error: -[Module.SuiteName testFoo] : XCTAssertEqual failed: ...
        // /path/to/File.swift:42:9: error: -[Module.SuiteName testFoo] : ...
        try! NSRegularExpression(pattern: "^(.+?):(\\d+)(?::\\d+)?: error: -\\[([^ ]+) ([^\\]]+)\\] : (.*)$")
    }()

    private struct ParsedTestCase {
        let suite: String
        let testCase: String
        let passed: Bool
    }

    private func parseTestCase(_ line: String) -> ParsedTestCase? {
        let ns = line as NSString
        guard let m = Self.testCaseRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let module = ns.substring(with: m.range(at: 1))
        let method = ns.substring(with: m.range(at: 2))
        let outcome = ns.substring(with: m.range(at: 3))
        // Strip the module prefix for display: "BeanLedgerTests.AccountsSnapshotTests" → "AccountsSnapshotTests"
        let suite = module.split(separator: ".").last.map(String.init) ?? module
        return ParsedTestCase(suite: suite, testCase: method, passed: outcome == "passed")
    }

    private func parseFailureMessage(_ line: String) -> PendingFailure? {
        let ns = line as NSString
        guard let m = Self.failureMessageRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let file = ns.substring(with: m.range(at: 1))
        let lineNum = Int(ns.substring(with: m.range(at: 2)))
        let module = ns.substring(with: m.range(at: 3))
        let method = ns.substring(with: m.range(at: 4))
        let message = ns.substring(with: m.range(at: 5))
        let suite = module.split(separator: ".").last.map(String.init) ?? module
        return PendingFailure(
            testID: "\(suite)/\(method)",
            file: file,
            lineNumber: lineNum,
            message: message
        )
    }

    private func match(line: String, pattern: NSRegularExpression, captureIndex: Int) -> String? {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > captureIndex else { return nil }
        let r = m.range(at: captureIndex)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    /// Returns all capture groups (index 0 = whole match, 1+ = groups)
    /// or nil if pattern didn't match.
    private func matches(line: String, pattern: NSRegularExpression) -> [String]? {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    /// `1.234s` / `1m 14s` / `1h 02m`. Always one decimal for sub-minute.
    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.2fs", seconds)
        }
        let intSec = Int(seconds.rounded())
        let h = intSec / 3600
        let m = (intSec % 3600) / 60
        let s = intSec % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return String(format: "%dm %02ds", m, s)
    }
}
