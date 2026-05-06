import XCTest
@testable import VibeChardCore

final class CompletionsInstallerTests: XCTestCase {

    // MARK: - shell detection

    func testDetectFromZshAbsolutePath() {
        XCTAssertEqual(CompletionShell.detect(shellEnv: "/bin/zsh"), .zsh)
    }

    func testDetectFromBashHomebrewPath() {
        // Common Apple-silicon Homebrew location.
        XCTAssertEqual(CompletionShell.detect(shellEnv: "/opt/homebrew/bin/bash"), .bash)
    }

    func testDetectFromFishPath() {
        XCTAssertEqual(CompletionShell.detect(shellEnv: "/opt/homebrew/bin/fish"), .fish)
    }

    func testDetectIsCaseInsensitive() {
        // Defensive — some installers symlink with mixed case.
        XCTAssertEqual(CompletionShell.detect(shellEnv: "/usr/local/bin/ZSH"), .zsh)
    }

    func testDetectReturnsNilForMissingEnv() {
        XCTAssertNil(CompletionShell.detect(shellEnv: nil))
    }

    func testDetectReturnsNilForEmptyEnv() {
        XCTAssertNil(CompletionShell.detect(shellEnv: ""))
        XCTAssertNil(CompletionShell.detect(shellEnv: "   "))
    }

    func testDetectReturnsNilForUnknownShell() {
        XCTAssertNil(CompletionShell.detect(shellEnv: "/usr/local/bin/csh"))
        XCTAssertNil(CompletionShell.detect(shellEnv: "/bin/sh"))
    }

    // MARK: - install plan

    func testZshPlanLandsInDotZshCompletions() {
        let plan = CompletionsInstaller.plan(shell: .zsh, home: "/Users/me")
        XCTAssertEqual(plan.shell, .zsh)
        XCTAssertEqual(plan.targetPath, "/Users/me/.zsh/completions/_vch")
    }

    func testZshPlanIncludesFpathHint() {
        let plan = CompletionsInstaller.plan(shell: .zsh, home: "/Users/me")
        XCTAssertTrue(plan.postInstallHint.contains("fpath="),
                      "zsh hint must mention fpath= so users know to wire it up")
        XCTAssertTrue(plan.postInstallHint.contains("compinit"),
                      "zsh hint must mention compinit")
        XCTAssertTrue(plan.postInstallHint.contains("/Users/me/.zsh/completions"),
                      "zsh hint must reference the actual install dir")
    }

    func testBashPlanUsesXDGStandardLocation() {
        let plan = CompletionsInstaller.plan(shell: .bash, home: "/Users/me")
        XCTAssertEqual(plan.targetPath,
                       "/Users/me/.local/share/bash-completion/completions/vch")
    }

    func testFishPlanUsesAutoLoadedDirectoryWithNoHint() {
        let plan = CompletionsInstaller.plan(shell: .fish, home: "/Users/me")
        XCTAssertEqual(plan.targetPath,
                       "/Users/me/.config/fish/completions/vch.fish")
        XCTAssertEqual(plan.postInstallHint, "",
                       "fish auto-loads from this dir, no hint should be printed")
    }

    func testPlanStripsTrailingSlashFromHome() {
        // Defensive: NSHomeDirectory() shouldn't ship a trailing slash,
        // but we don't want to emit double-slash paths if a tester
        // hands one in.
        let plan = CompletionsInstaller.plan(shell: .zsh, home: "/Users/me/")
        XCTAssertEqual(plan.targetPath, "/Users/me/.zsh/completions/_vch")
    }

    func testPlanPreservesRootHome() {
        // Pathological but valid input — don't strip the only `/`.
        let plan = CompletionsInstaller.plan(shell: .zsh, home: "/")
        XCTAssertEqual(plan.targetPath, "/.zsh/completions/_vch")
    }
}
