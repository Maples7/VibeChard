import XCTest

@testable import VibeChardCore

final class ErrorsTests: XCTestCase {

    // MARK: - worktreeBusy (#65)

    func testWorktreeBusyMessageRecommendsForceFlag() {
        // The error message must point users at `--force`, not
        // `--allow-dirty`. The two flags now mean different things:
        // `--force` overrides held-open files, `--allow-dirty`
        // overrides uncommitted changes. Conflating them in the
        // diagnostic is what motivated #65.
        let err = VibeChardError.worktreeBusy(
            path: "/tmp/my-worktree",
            holders: [
                WorktreeHolder(pid: 1234, command: "Code Helper", samplePath: "/tmp/my-worktree/x.swift")
            ]
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("--force"),
                      "worktreeBusy must recommend --force; got: \(msg)")
        XCTAssertFalse(msg.contains("--allow-dirty"),
                       "worktreeBusy must NOT mention --allow-dirty (#65 split); got: \(msg)")
        XCTAssertTrue(msg.contains("/tmp/my-worktree"))
        XCTAssertTrue(msg.contains("1234"))
    }

    func testWorktreeBusyMessagePluralizes() {
        let err = VibeChardError.worktreeBusy(
            path: "/tmp/wt",
            holders: [
                WorktreeHolder(pid: 1, command: "a", samplePath: "/tmp/wt/a"),
                WorktreeHolder(pid: 2, command: "b", samplePath: "/tmp/wt/b")
            ]
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("2 processes"),
                      "expected pluralized 'processes'; got: \(msg)")
    }

    func testWorktreeBusyMessageSingularForOneHolder() {
        let err = VibeChardError.worktreeBusy(
            path: "/tmp/wt",
            holders: [WorktreeHolder(pid: 1, command: "a", samplePath: "/tmp/wt/a")]
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("1 process "),
                      "expected singular 'process '; got: \(msg)")
    }

    // MARK: - simulatorTemplateBooted (#66)

    func testSimulatorTemplateBootedMessageIsActionable() {
        let err = VibeChardError.simulatorTemplateBooted(
            name: "iPhone 16",
            udid: "ABCDEF12-3456-7890-ABCD-EF1234567890"
        )
        let msg = err.description
        // Point at the human-readable template name so the user can
        // tell which warm template needs attention without grepping
        // through `simctl list` for the UDID.
        XCTAssertTrue(msg.contains("iPhone 16"), "expected template name in: \(msg)")
        // Surface the raw UDID — users copy-paste it straight into
        // `xcrun simctl shutdown <udid>`.
        XCTAssertTrue(msg.contains("ABCDEF12-3456-7890-ABCD-EF1234567890"),
                      "expected full UDID for copy-paste in: \(msg)")
        XCTAssertTrue(msg.contains("xcrun simctl shutdown"),
                      "expected manual remediation hint in: \(msg)")
        // Mention the opt-in flag so users know there's a one-shot
        // delegation knob and we're not just refusing to help.
        XCTAssertTrue(msg.contains("--shutdown-template"),
                      "expected --shutdown-template hint in: \(msg)")
    }
}
