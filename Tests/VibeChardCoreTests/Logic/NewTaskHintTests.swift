import XCTest
@testable import VibeChardCore

final class NewTaskHintTests: XCTestCase {

    func testEmitsHintOnTTYWithCleanEnv() {
        XCTAssertEqual(
            NewTaskHint.message(stdoutIsTTY: true, env: [:]),
            NewTaskHint.hintMessage
        )
    }

    func testStaysSilentWhenStdoutIsNotATTY() {
        // Scripting — never spam piped stdout consumers' stderr.
        XCTAssertNil(NewTaskHint.message(stdoutIsTTY: false, env: [:]))
    }

    func testStaysSilentWhenShellHelperSentinelIsSet() {
        // `eval "$(vch shellenv)"` exports VCH_SHELL_HELPER=1; the
        // user already has vch_new, no point nagging.
        XCTAssertNil(NewTaskHint.message(
            stdoutIsTTY: true,
            env: ["VCH_SHELL_HELPER": "1"]
        ))
    }

    func testStaysSilentWhenHintSuppressedByEnv() {
        for value in ["0", "false", "FALSE", "No"] {
            XCTAssertNil(
                NewTaskHint.message(
                    stdoutIsTTY: true,
                    env: ["VCH_NEW_HINT": value]
                ),
                "expected nil for VCH_NEW_HINT=\(value)"
            )
        }
    }

    func testEmptyShellHelperEnvDoesNotCount() {
        // An empty value should not be treated as "helpers loaded".
        // Defensive: shell idioms occasionally end up exporting blanks.
        XCTAssertEqual(
            NewTaskHint.message(
                stdoutIsTTY: true,
                env: ["VCH_SHELL_HELPER": ""]
            ),
            NewTaskHint.hintMessage
        )
    }

    func testTruthyHintOptInValuesStillEmit() {
        // We treat anything except 0/false/no as "show me the hint".
        XCTAssertEqual(
            NewTaskHint.message(stdoutIsTTY: true, env: ["VCH_NEW_HINT": "1"]),
            NewTaskHint.hintMessage
        )
    }

    // MARK: - command-level suppressions (#98 follow-up)

    /// `vch new [<name>] --adopt-current` means the user is already
    /// inside the worktree they want vch to know about — auto-cd has
    /// nothing to do. Suppress the hint regardless of TTY / env state
    /// so the per-command policy lives next to the rest of the rules.
    func testStaysSilentWhenAdoptingCurrentWorktree() {
        XCTAssertNil(NewTaskHint.message(
            stdoutIsTTY: true,
            env: [:],
            adoptCurrent: true
        ))
    }

    /// `--exec "<cmd>"` runs an `execve` immediately after vch
    /// finishes its own work; anything printed to stderr right before
    /// would be visually attached to the agent's output. Suppress.
    func testStaysSilentWhenExecProvided() {
        XCTAssertNil(NewTaskHint.message(
            stdoutIsTTY: true,
            env: [:],
            execProvided: true
        ))
    }

    /// `--cd` flips stdout into "path only" machine-readable mode
    /// consumed by `vch_new`; the wrapper is already doing the cd, so
    /// the human-facing hint is both unnecessary and dangerous (a
    /// trailing newline pair could confuse `eval`-style consumers).
    func testStaysSilentWhenCdProvided() {
        XCTAssertNil(NewTaskHint.message(
            stdoutIsTTY: true,
            env: [:],
            cdProvided: true
        ))
    }

    /// The three command-level suppressions are checked BEFORE the
    /// TTY / env-opt-out checks. That ordering matters: if the user
    /// passes `--adopt-current`, we should not print the hint even
    /// when stdout is a TTY with default env. Codifying it as a
    /// test stops a future reorder from re-introducing the bug.
    func testCommandLevelSuppressionsBeatTtyAndEnv() {
        for combo in [
            (adoptCurrent: true,  execProvided: false, cdProvided: false),
            (adoptCurrent: false, execProvided: true,  cdProvided: false),
            (adoptCurrent: false, execProvided: false, cdProvided: true),
        ] {
            XCTAssertNil(
                NewTaskHint.message(
                    stdoutIsTTY: true,
                    env: ["VCH_NEW_HINT": "1"],
                    adoptCurrent: combo.adoptCurrent,
                    execProvided: combo.execProvided,
                    cdProvided: combo.cdProvided
                ),
                "expected nil for combo \(combo)"
            )
        }
    }
}
