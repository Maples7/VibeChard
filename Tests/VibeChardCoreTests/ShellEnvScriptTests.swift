import XCTest
@testable import VibeChardCore

final class ShellEnvScriptTests: XCTestCase {

    func testZshBashContainsBothHelperFunctions() {
        let script = ShellEnvScript.zshBash
        XCTAssertTrue(script.contains("vch_cd()"),
                      "missing vch_cd function")
        XCTAssertTrue(script.contains("vch_clean()"),
                      "missing vch_clean function")
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
}
