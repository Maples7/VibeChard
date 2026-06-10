import XCTest
@testable import VibeChardCore

final class ProgressHeartbeatTests: XCTestCase {
    func testLineSurfacesElapsedAndLastOutput() {
        let line = ProgressHeartbeat.line(
            elapsedSeconds: 192,
            secondsSinceLastOutput: 4
        )
        XCTAssertEqual(line, "→ still running (3m 12s elapsed, last output 4s ago)")
    }

    func testLineUsesWholeSecondsBelowAMinute() {
        let line = ProgressHeartbeat.line(
            elapsedSeconds: 30.4,
            secondsSinceLastOutput: 0.6
        )
        // 30.4 rounds to 30s; 0.6 rounds to 1s — sub-second jitter is
        // collapsed so the heartbeat stays terse.
        XCTAssertEqual(line, "→ still running (30s elapsed, last output 1s ago)")
    }

    func testHumanizeFormatsSecondsMinutesAndHours() {
        XCTAssertEqual(ProgressHeartbeat.humanize(0), "0s")
        XCTAssertEqual(ProgressHeartbeat.humanize(4), "4s")
        XCTAssertEqual(ProgressHeartbeat.humanize(59.4), "59s")
        XCTAssertEqual(ProgressHeartbeat.humanize(60), "1m 00s")
        XCTAssertEqual(ProgressHeartbeat.humanize(624), "10m 24s")
        XCTAssertEqual(ProgressHeartbeat.humanize(3660), "1h 01m")
    }

    func testHumanizeClampsNegativeInputToZero() {
        // Defensive: clock skew between the activity timestamp and the
        // heartbeat sample must never render a negative duration.
        XCTAssertEqual(ProgressHeartbeat.humanize(-5), "0s")
    }
}
