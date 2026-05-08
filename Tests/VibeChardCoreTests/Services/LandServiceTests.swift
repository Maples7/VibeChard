import XCTest
@testable import VibeChardCore

/// `LandService` is largely covered by
/// `LandServiceIntegrationTests` (real git, real worktrees), but a few
/// branches are awkward to provoke through real git — most notably the
/// "merge succeeded but auto-`vch rm` failed" path. When that happens
/// the merge has already landed; LandService swallows the rm error and
/// surfaces it via `Outcome.removeError` instead of letting the user
/// think the whole operation failed. This file pins that contract with
/// a fast unit test using `FakeGitClient` + `InMemoryFileSystem`.
final class LandServiceTests: XCTestCase {

    // MARK: - removeError fallback (#7)

    func testMergeSucceedsButAutoRemoveFailsSetsRemoveError() throws {
        let mainRepo = "/repo"
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let task = try TaskName("alpha")
        let wtPath = workspace.worktreePath(for: task)

        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(wtPath)
        fs.seedDirectory(workspace.vchDir(for: task))
        let state = TaskState(
            name: "alpha",
            branch: "agent/alpha",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbee",
            baseBranch: "main"
        )
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())

        let git = FakeGitClient()
        git.branches = ["main", "agent/alpha"]
        git.entries = [
            WorktreeEntry(path: mainRepo, branch: "main"),
            WorktreeEntry(path: wtPath, branch: "agent/alpha"),
        ]
        git.currentBranchByCwd = [mainRepo: "main"]
        git.revListCountByRange["main..agent/alpha"] = 2
        git.diffNamesByRange["main..agent/alpha"] = ["src/foo.swift"]
        git.lastSubjectByBranch["agent/alpha"] = "feat: foo"
        // Trigger the auto-rm failure: `removeTask` consults
        // `statusIsDirty(worktreeCwd:)` on the *task* worktree (which
        // `vch land` does NOT pre-check — only main's status counts as a
        // pre-flight). A dirty task worktree post-merge is a realistic
        // scenario: the user could have untracked scratch files in the
        // task worktree that survived the merge.
        git.dirtyWorktrees = [wtPath]

        let service = LandService(workspace: workspace, git: git, fs: fs, clock: SystemClock())
        let outcome = try service.land(task, options: .init())

        XCTAssertTrue(outcome.merged,
                      "merge must still report success — only the post-merge cleanup failed")
        XCTAssertFalse(outcome.removed, "auto-rm did not complete")
        XCTAssertNotNil(outcome.removeError,
                        "removeError must be populated so the CLI can surface it")
        XCTAssertTrue(
            outcome.removeError?.contains("dirtyWorktree") ?? false ||
            outcome.removeError?.contains(wtPath) ?? false,
            "removeError should embed the underlying error for the user; got '\(outcome.removeError ?? "nil")'"
        )
        XCTAssertEqual(outcome.into, "main")
        XCTAssertEqual(git.mergeCalls.count, 1,
                       "merge must have run before the cleanup branch")
        XCTAssertEqual(git.mergeCalls.first?.branch, "agent/alpha")
    }

    func testKeepFlagSkipsRemovalEntirely() throws {
        // Belt-and-suspenders for the contract above: --keep must not
        // even attempt removeTask, so removeError is always nil.
        let mainRepo = "/repo"
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let task = try TaskName("alpha")
        let wtPath = workspace.worktreePath(for: task)

        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(wtPath)
        fs.seedDirectory(workspace.vchDir(for: task))
        let state = TaskState(
            name: "alpha",
            branch: "agent/alpha",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbee",
            baseBranch: "main"
        )
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())

        let git = FakeGitClient()
        git.branches = ["main", "agent/alpha"]
        git.entries = [
            WorktreeEntry(path: mainRepo, branch: "main"),
            WorktreeEntry(path: wtPath, branch: "agent/alpha"),
        ]
        git.currentBranchByCwd = [mainRepo: "main"]
        git.revListCountByRange["main..agent/alpha"] = 1
        git.diffNamesByRange["main..agent/alpha"] = ["src/foo.swift"]
        git.lastSubjectByBranch["agent/alpha"] = "feat: foo"
        // Even with a dirty task worktree, --keep should not touch it.
        git.dirtyWorktrees = [wtPath]

        let service = LandService(workspace: workspace, git: git, fs: fs, clock: SystemClock())
        let outcome = try service.land(task, options: .init(keep: true))

        XCTAssertTrue(outcome.merged)
        XCTAssertFalse(outcome.removed,
                       "--keep means we never attempted removal, so removed=false")
        XCTAssertNil(outcome.removeError,
                     "--keep skips removeTask entirely — no error to surface")
        XCTAssertEqual(git.removeCalls.count, 0,
                       "worktreeRemove must not be called under --keep")
        XCTAssertEqual(git.branchDeleteCalls.count, 0,
                       "branch must not be deleted under --keep")
    }
}
