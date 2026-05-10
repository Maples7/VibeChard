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
}
