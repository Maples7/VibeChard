import XCTest
@testable import VibeChardCore

final class TaskShortcutDispatcherTests: XCTestCase {

    // MARK: - Regression for #82

    /// Both `prune` and `clean` are real subcommands. In v0.5.0 the
    /// dispatcher carried its own hardcoded copy of the reserved-name
    /// list and that copy drifted out of sync with `TaskName.reserved`
    /// — neither `prune` nor `clean` was listed there, so the
    /// dispatcher turned `vch prune` into `["exec", "prune", "--",
    /// $SHELL]` and `TaskName` then rejected it. With the dispatcher
    /// now driven directly off `TaskName.reserved`, every registered
    /// subcommand short-circuits as it should.
    func testPruneIsNotRewrittenAsSugar() {
        XCTAssertNil(
            TaskShortcutDispatcher.rewriteIfSugar(["prune"], env: ["SHELL": "/bin/zsh"])
        )
        XCTAssertNil(
            TaskShortcutDispatcher.rewriteIfSugar(["prune", "--rm"], env: ["SHELL": "/bin/zsh"])
        )
    }

    func testCleanIsNotRewrittenAsSugar() {
        XCTAssertNil(
            TaskShortcutDispatcher.rewriteIfSugar(["clean", "task-1"], env: ["SHELL": "/bin/zsh"])
        )
    }

    // MARK: - Every reserved name short-circuits

    /// Guards against future drift: if someone adds a new subcommand,
    /// adds it to `TaskName.reserved`, but forgets to test it, the
    /// dispatcher still does the right thing because there's only one
    /// list now.
    func testEveryReservedNameShortCircuits() {
        for name in TaskName.reserved {
            XCTAssertNil(
                TaskShortcutDispatcher.rewriteIfSugar([name], env: ["SHELL": "/bin/zsh"]),
                "expected reserved name '\(name)' to dispatch as a subcommand, not sugar"
            )
        }
    }

    // MARK: - Sugar path still works

    func testUnknownNameRewritesToExecShell() {
        let result = TaskShortcutDispatcher.rewriteIfSugar(
            ["my-feature"],
            env: ["SHELL": "/bin/zsh"]
        )
        XCTAssertEqual(result, ["exec", "my-feature", "--", "/bin/zsh"])
    }

    func testForwardsExtraArgumentsAfterTaskName() {
        let result = TaskShortcutDispatcher.rewriteIfSugar(
            ["my-feature", "-l"],
            env: ["SHELL": "/bin/zsh"]
        )
        XCTAssertEqual(result, ["exec", "my-feature", "--", "/bin/zsh", "-l"])
    }

    func testDefaultsToZshWhenShellUnset() {
        let result = TaskShortcutDispatcher.rewriteIfSugar(
            ["my-feature"],
            env: [:]
        )
        XCTAssertEqual(result, ["exec", "my-feature", "--", "/bin/zsh"])
    }

    func testDefaultsToZshWhenShellEmpty() {
        let result = TaskShortcutDispatcher.rewriteIfSugar(
            ["my-feature"],
            env: ["SHELL": "   "]
        )
        XCTAssertEqual(result, ["exec", "my-feature", "--", "/bin/zsh"])
    }

    // MARK: - Edge cases

    func testEmptyArgvReturnsNil() {
        XCTAssertNil(TaskShortcutDispatcher.rewriteIfSugar([], env: [:]))
    }

    func testFlagAsFirstArgReturnsNil() {
        // `vch --help` / `vch --version` must reach ArgumentParser.
        XCTAssertNil(
            TaskShortcutDispatcher.rewriteIfSugar(["--help"], env: ["SHELL": "/bin/zsh"])
        )
        XCTAssertNil(
            TaskShortcutDispatcher.rewriteIfSugar(["-h"], env: ["SHELL": "/bin/zsh"])
        )
    }
}
