import XCTest

@testable import VibeChardCore

final class ErrorsTests: XCTestCase {

    // MARK: - land diagnostics (#124)

    func testLandMainNotOnIntoMessageNamesTargetAndCurrentBranch() {
        let err = VibeChardError.landMainNotOnInto(
            currentBranch: "v3.1.0",
            want: "main"
        )
        let msg = err.description

        XCTAssertTrue(msg.contains("target branch is 'main'"),
                      "expected target branch in: \(msg)")
        XCTAssertTrue(msg.contains("main worktree is currently on 'v3.1.0'"),
                      "expected current branch in: \(msg)")
        XCTAssertTrue(msg.contains("git switch main"),
                      "expected direct switch hint in: \(msg)")
        XCTAssertFalse(msg.contains("pass --into"),
                       "must not suggest --into after the target has already been resolved; got: \(msg)")
    }

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

    // MARK: - worktreeBusy classification + path polish (#75)

    /// When every holder is a known background helper, the diagnostic
    /// must NOT say "close the editor" — there is no editor to close.
    /// Instead it must hint that the holders release on their own and
    /// that `--force` is safe when `git status` is clean.
    func testWorktreeBusyAllBackgroundUsesWaitOrForceHint() {
        let err = VibeChardError.worktreeBusy(
            path: "/repos/Demo-alpha",
            holders: [
                WorktreeHolder(pid: 100, command: "sourcekit-lsp",
                               samplePath: "/repos/Demo-alpha/Sources/A.swift"),
                WorktreeHolder(pid: 200, command: "Code Helper (Plugin)",
                               samplePath: "/repos/Demo-alpha/Sources/B.swift"),
            ]
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("background helpers"),
                      "expected 'background helpers' framing; got: \(msg)")
        XCTAssertTrue(msg.contains("git status"),
                      "expected `git status` is-clean cue; got: \(msg)")
        XCTAssertTrue(msg.contains("--force"))
        // No need to tell the user to close anything — there's no
        // foreground editor in the holder set.
        XCTAssertFalse(msg.contains("close the editor"),
                       "all-background message must not say 'close the editor'; got: \(msg)")
        // Single-section layout: no group headers.
        XCTAssertFalse(msg.contains("interactive ("),
                       "single-section layout shouldn't render group headers; got: \(msg)")
        XCTAssertFalse(msg.contains("background ("),
                       "single-section layout shouldn't render group headers; got: \(msg)")
    }

    /// All-interactive holders → keep the strong "close the editor"
    /// framing, no mention of background helpers.
    func testWorktreeBusyAllInteractiveUsesCloseTheEditorHint() {
        let err = VibeChardError.worktreeBusy(
            path: "/repos/Demo-alpha",
            holders: [
                WorktreeHolder(pid: 1, command: "nvim",
                               samplePath: "/repos/Demo-alpha/Sources/A.swift")
            ]
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("close the listed editor / shell"),
                      "expected 'close the listed editor / shell' framing; got: \(msg)")
        XCTAssertFalse(msg.contains("background helpers"),
                       "no background holders → don't mention them; got: \(msg)")
        XCTAssertTrue(msg.contains("--force"))
    }

    /// Mixed holders → two grouped sections (interactive first, since
    /// that's the one the user has to act on), and a hint that pivots
    /// on the `git status` clean check.
    func testWorktreeBusyMixedRendersTwoSectionsInOrder() {
        let err = VibeChardError.worktreeBusy(
            path: "/repos/Demo-alpha",
            holders: [
                WorktreeHolder(pid: 100, command: "sourcekit-lsp",
                               samplePath: "/repos/Demo-alpha/Sources/A.swift"),
                WorktreeHolder(pid: 200, command: "Code",
                               samplePath: "/repos/Demo-alpha/Sources/B.swift"),
            ]
        )
        let msg = err.description
        // Both group headers must be present.
        XCTAssertTrue(msg.contains("interactive ("),
                      "expected interactive group header; got: \(msg)")
        XCTAssertTrue(msg.contains("background ("),
                      "expected background group header; got: \(msg)")
        // Interactive section must come first so the user sees the
        // actionable group up top.
        let interactiveIdx = msg.range(of: "interactive (")!.lowerBound
        let backgroundIdx  = msg.range(of: "background (")!.lowerBound
        XCTAssertLessThan(interactiveIdx, backgroundIdx,
                          "interactive group must come before background group; got: \(msg)")
        // Hint pivots on `git status` clean.
        XCTAssertTrue(msg.contains("git status"),
                      "expected `git status` cue in mixed hint; got: \(msg)")
    }

    /// `samplePath == worktreePath` (typical shell `cwd`) renders as
    /// `(cwd)` rather than as a useless echo of the worktree root.
    func testWorktreeBusySamplePathAtRootRendersAsCwd() {
        let err = VibeChardError.worktreeBusy(
            path: "/repos/Demo-alpha",
            holders: [
                WorktreeHolder(pid: 999, command: "zsh",
                               samplePath: "/repos/Demo-alpha")
            ]
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("(cwd)"),
                      "expected (cwd) for worktree-root samplePath; got: \(msg)")
    }

    /// Strict subpaths render relative to the worktree (with `./`)
    /// so the long absolute prefix doesn't dominate every line.
    func testWorktreeBusySubpathRendersRelative() {
        let err = VibeChardError.worktreeBusy(
            path: "/Users/me/repos/Demo-alpha",
            holders: [
                WorktreeHolder(pid: 1, command: "nvim",
                               samplePath: "/Users/me/repos/Demo-alpha/Sources/Views/Foo.swift")
            ]
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("./Sources/Views/Foo.swift"),
                      "expected ./relative path; got: \(msg)")
        // Avoid double-printing the absolute prefix on the holder
        // row (it already appears in the header).
        XCTAssertFalse(msg.contains("  /Users/me/repos/Demo-alpha/Sources"),
                       "holder row should not echo the absolute path; got: \(msg)")
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

    func testSimulatorPlatformUnavailableMessageIsActionableAndBusinessExit() {
        let err = VibeChardError.simulatorBindingPlatformUnavailable(
            taskName: "alpha",
            platform: "iOS Simulator",
            candidates: ["Apple Watch Series 10-vch-alpha"]
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("alpha"), "expected task name in: \(msg)")
        XCTAssertTrue(msg.contains("iOS Simulator"), "expected platform in: \(msg)")
        XCTAssertTrue(msg.contains("--device <name>"), "expected device hint in: \(msg)")
        XCTAssertTrue(msg.contains("Apple Watch Series 10-vch-alpha"),
                      "expected candidate listing in: \(msg)")
        XCTAssertEqual(err.exitCode, ExitCode.business)
    }

    func testSimulatorPlatformUnknownMessageIsActionableAndBusinessExit() {
        let udid = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        let err = VibeChardError.simulatorPlatformUnknown(
            udid: udid,
            name: "Apple Watch Series 10-vch-alpha"
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("Apple Watch Series 10-vch-alpha"),
                      "expected clone name in: \(msg)")
        XCTAssertTrue(msg.contains("ABCDEF12"),
                      "expected UDID prefix in: \(msg)")
        XCTAssertTrue(msg.contains("--device <name>"),
                      "expected explicit device remediation in: \(msg)")
        XCTAssertTrue(msg.contains("--runtime <version>"),
                      "expected optional runtime hint in: \(msg)")
        XCTAssertEqual(err.exitCode, ExitCode.business)
    }
}
