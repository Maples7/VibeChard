import Foundation

/// Renders an `XcresultSummary` into the same human-readable shape
/// `TestOutputSummarizer.render(colorize:)` produces. Used when the
/// streaming parser came back empty (e.g. a swift-testing-only target,
/// per #45) but xcresult is available.
///
/// The renderer is a thin formatter on top of `XcresultSummary` —
/// keeping it separate from the streaming parser avoids mutating
/// `TestOutputSummarizer`'s internal state and lets each path stay
/// independently testable.
///
/// Per-suite rollup lines (e.g. `AccountsSnapshotTests  3 passed in
/// 0.020s`) are *not* rendered here: `xcresulttool get test-results
/// summary` does not expose per-suite counts. Users who need that
/// breakdown can pass `--verbose` to mirror xcodebuild's full log.
public enum XcresultRenderer {

    /// `logPath` (#69) is appended on the trailing line when the run
    /// status is `.unknown`, so the user can tail the firehose
    /// without scrolling back to the launch banner.
    public static func render(_ summary: XcresultSummary, colorize: Bool, logPath: String? = nil) -> String {
        var out: [String] = []

        // Failures first — same convention as `TestOutputSummarizer`.
        if !summary.failures.isEmpty {
            for f in summary.failures {
                let head = "✗ \(f.suite)/\(f.testCase)"
                out.append(ANSI.wrap(head, .fail, enabled: colorize))
                for line in f.message.split(separator: "\n", omittingEmptySubsequences: false) {
                    out.append("    \(line)")
                }
                out.append("")
            }
        }

        let total = summary.totalPassed + summary.totalFailed
        let durStr = summary.totalDurationSeconds.map(formatDuration) ?? "?"

        let head: String
        switch summary.status {
        case .succeeded:
            let line = "✓ \(total) passed in \(durStr)   ** TEST SUCCEEDED **"
            head = ANSI.wrap(line, .ok, enabled: colorize)
        case .failed:
            let line = "✗ \(summary.totalFailed) failed, \(summary.totalPassed) passed in \(durStr)   ** TEST FAILED **"
            head = ANSI.wrap(line, .fail, enabled: colorize)
        case .unknown:
            head = "? test status unknown — see full log"
        }
        out.append(head)
        // #69: same trailing log-path hint as `TestOutputSummarizer`.
        if summary.status == .unknown, let path = logPath, !path.isEmpty {
            out.append("   → log: \(path)")
        }
        return out.joined(separator: "\n")
    }

    // Inlined copy of `TestOutputSummarizer.formatDuration` — keeping a
    // private duplicate here is cheaper than promoting that helper to
    // an internal utility just for one call site.
    private static func formatDuration(_ seconds: Double) -> String {
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
