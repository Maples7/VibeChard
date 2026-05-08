import XCTest
@testable import VibeChardCore

final class ShellEnvScriptTests: XCTestCase {

    func testZshBashContainsBothHelperFunctions() {
        let script = ShellEnvScript.zshBash
        XCTAssertTrue(script.contains("vch_cd()"),
                      "missing vch_cd function")
        XCTAssertTrue(script.contains("vch_new()"),
                      "missing vch_new function")
        XCTAssertTrue(script.contains("vch_clean()"),
                      "missing vch_clean function")
    }

    func testVchNewDelegatesWhenExecFlagPresent() {
        // When `--exec` is requested vch replaces itself with the agent
        // via execve; capturing stdout to `cd` would interleave the
        // path with the agent's output. The helper must detect this
        // and forward the call without `cd`.
        let script = ShellEnvScript.zshBash
        XCTAssertTrue(script.contains("--exec|--exec=*"),
                      "vch_new must short-circuit when --exec is in argv")
    }

    func testVchNewUsesCommandVchToAvoidAliasRecursion() {
        // Same reason as vch_cd: the helper should not call itself if
        // a user aliases `vch`.
        XCTAssertTrue(ShellEnvScript.zshBash.contains("command vch new"),
                      "vch_new must call `command vch new` to bypass shell aliases")
    }

    func testVchNewUsesCdContractForPathCapture() {
        // #32B: when the helper captures stdout to drive the parent
        // shell's `cd`, it must opt into the machine-readable
        // `--cd` contract. Without this we'd silently break the
        // moment vch added another stdout line. Eats our own dog
        // food and pins the contract to a regression-safe assert.
        XCTAssertTrue(
            ShellEnvScript.zshBash.contains("command vch new --cd"),
            "vch_new must invoke `command vch new --cd` so stdout = path only"
        )
    }

    func testZshBashUsesCommandVchToAvoidRecursionFromAlias() {
        // If a user has aliased `vch=...`, the helper must invoke the
        // real binary via `command vch path`. Bare `vch path` would
        // reuse the alias.
        XCTAssertTrue(ShellEnvScript.zshBash.contains("command vch path"),
                      "must call `command vch` to bypass shell aliases")
    }

    func testZshBashGuardsVchCleanAgainstNonWorktrees() {
        // `vch_clean` should not rm -rf .agent-build outside a vch
        // worktree (i.e. one with .vch/).
        XCTAssertTrue(ShellEnvScript.zshBash.contains(".vch"),
                      "vch_clean must check for .vch/ before deleting .agent-build")
    }

    func testHeaderMentionsEvalUsage() {
        XCTAssertTrue(ShellEnvScript.header.contains("eval"))
    }

    func testZshBashExportsShellHelperSentinel() {
        // #32A: sourcing shellenv must mark the shell as helper-loaded
        // so `vch new` knows it can skip its install-the-helpers hint.
        XCTAssertTrue(
            ShellEnvScript.zshBash.contains("export VCH_SHELL_HELPER=1"),
            "shellenv must export VCH_SHELL_HELPER=1 (used by NewTaskHint)"
        )
    }
}
