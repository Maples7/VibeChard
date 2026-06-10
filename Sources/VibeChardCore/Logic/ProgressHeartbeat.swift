import Foundation

/// Renders the periodic "still running" heartbeat that `vch test`
/// emits during long, output-quiet xcodebuild phases (#167).
///
/// On a cold watchOS test run the wrapper can sit silent for many
/// minutes while xcodebuild streams build / codesign / validate / test
/// output only to the tee'd `.vch/last-test.log`. Without a heartbeat an
/// automated agent (or a human) cannot tell "slow but progressing" from
/// "hung", and may kill a healthy run. Each line surfaces two facts: how
/// long the child has been running, and how long since it last produced
/// any output — the latter being its liveness signal.
public enum ProgressHeartbeat {
    /// `→ still running (3m 12s elapsed, last output 4s ago)`
    ///
    /// - Parameters:
    ///   - elapsedSeconds: wall-clock since the xcodebuild child launched.
    ///   - secondsSinceLastOutput: time since the child last wrote any
    ///     bytes to the tee'd log; small values mean it is alive.
    public static func line(
        elapsedSeconds: Double,
        secondsSinceLastOutput: Double
    ) -> String {
        "→ still running (\(humanize(elapsedSeconds)) elapsed, last output \(humanize(secondsSinceLastOutput)) ago)"
    }

    /// Compact `Hh MMm` / `Mm SSs` / `Ss` duration. Whole-second
    /// precision keeps the heartbeat terse; sub-second jitter is noise
    /// for a line that only fires every several seconds.
    static func humanize(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            return "\(total)s"
        }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h)h \(String(format: "%02d", m))m"
        }
        return "\(m)m \(String(format: "%02d", s))s"
    }
}
