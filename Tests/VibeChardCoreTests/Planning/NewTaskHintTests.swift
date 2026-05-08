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
}
