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

    // MARK: - --push (#49)

    /// Helper: build a fully-seeded "happy path" world where a merge of
    /// `agent/alpha` into `main` is guaranteed to succeed, so each test
    /// can focus on the push variants.
    private func makeHappyPathWorld(
        upstreamRemote: String? = nil
    ) throws -> (workspace: Workspace, task: TaskName, fs: InMemoryFileSystem, git: FakeGitClient) {
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
        if let remote = upstreamRemote {
            git.upstreamRemoteByBranch["main"] = remote
        }
        return (workspace, task, fs, git)
    }

    func testPushDefaultRemoteUsesUpstreamConfig() throws {
        // `--push` (no explicit remote) and the resolved --into branch
        // has `branch.main.remote=origin` configured. Push must run
        // against that remote.
        let world = try makeHappyPathWorld(upstreamRemote: "origin")
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock()
        )

        let outcome = try service.land(world.task, options: .init(push: .defaultRemote))

        XCTAssertTrue(outcome.merged)
        XCTAssertTrue(outcome.pushed,
                      "push should have succeeded with the configured upstream")
        XCTAssertEqual(outcome.pushRemote, "origin")
        XCTAssertNil(outcome.pushError)
        XCTAssertEqual(world.git.pushCalls.count, 1)
        XCTAssertEqual(world.git.pushCalls.first?.remote, "origin")
        XCTAssertEqual(world.git.pushCalls.first?.branch, "main",
                       "push targets the resolved --into branch, not the task branch")
        XCTAssertEqual(world.git.pushCalls.first?.repoCwd, world.workspace.mainWorktreePath,
                       "push must run in the main worktree, not the task worktree (which has been removed)")
    }

    func testPushDefaultRemoteFallsBackToOriginWhenNoUpstreamConfigured() throws {
        // No `branch.main.remote` configured. Per the issue's spec,
        // `--push` should fall back to "origin" (matching what
        // `git push` would default to in most setups).
        let world = try makeHappyPathWorld(upstreamRemote: nil)
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock()
        )

        let outcome = try service.land(world.task, options: .init(push: .defaultRemote))

        XCTAssertTrue(outcome.pushed)
        XCTAssertEqual(outcome.pushRemote, "origin",
                       "fallback remote when no upstream is configured must be 'origin'")
        XCTAssertEqual(world.git.pushCalls.first?.remote, "origin")
    }

    func testPushExplicitRemoteOverridesUpstreamConfig() throws {
        // Even when `branch.main.remote=origin`, an explicit
        // `--push-to=upstream` must win.
        let world = try makeHappyPathWorld(upstreamRemote: "origin")
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock()
        )

        let outcome = try service.land(world.task, options: .init(push: .explicit("upstream")))

        XCTAssertTrue(outcome.pushed)
        XCTAssertEqual(outcome.pushRemote, "upstream")
        XCTAssertEqual(world.git.pushCalls.first?.remote, "upstream")
    }

    func testPushFailureDoesNotRollBackMerge() throws {
        // Issue #49 explicit requirement: "If push fails
        // (non-fast-forward, network), report it but don't roll back
        // the merge." pushed=false, pushError populated, merged=true.
        let world = try makeHappyPathWorld(upstreamRemote: "origin")
        world.git.pushError = .externalCommandFailed(
            cmd: "git push origin main",
            exitCode: 1,
            stderr: "remote: Updates were rejected because the tip of your current branch is behind"
        )
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock()
        )

        let outcome = try service.land(world.task, options: .init(push: .defaultRemote))

        XCTAssertTrue(outcome.merged,
                      "merge must still report success — only the push failed")
        XCTAssertEqual(world.git.mergeCalls.count, 1,
                       "merge ran once before the failed push attempt")
        XCTAssertFalse(outcome.pushed)
        XCTAssertEqual(outcome.pushRemote, "origin",
                       "pushRemote must surface even on failure so the CLI can show which remote vch tried")
        XCTAssertNotNil(outcome.pushError)
        XCTAssertTrue(
            outcome.pushError?.contains("rejected") ?? false ||
            outcome.pushError?.contains("git push") ?? false,
            "pushError should embed the underlying git failure; got '\(outcome.pushError ?? "nil")'"
        )
    }

    func testNoPushFlagMeansNoPushAttempt() throws {
        // Default `vch land` (no --push / --push-to) must never
        // contact a remote. Belt-and-suspenders for the
        // never-publish-without-asking contract.
        let world = try makeHappyPathWorld(upstreamRemote: "origin")
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock()
        )

        let outcome = try service.land(world.task, options: .init())

        XCTAssertTrue(outcome.merged)
        XCTAssertFalse(outcome.pushed)
        XCTAssertNil(outcome.pushRemote)
        XCTAssertNil(outcome.pushError)
        XCTAssertEqual(world.git.pushCalls.count, 0,
                       "git push must not be called when --push was not requested")
    }

    func testDryRunNeverPushesEvenWhenRequested() throws {
        // `--dry-run --push` must not attempt the push (the merge
        // didn't run). Outcome reflects "no push attempted".
        let world = try makeHappyPathWorld(upstreamRemote: "origin")
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock()
        )

        let outcome = try service.land(
            world.task,
            options: .init(dryRun: true, push: .defaultRemote)
        )

        XCTAssertFalse(outcome.merged, "dry-run never merges")
        XCTAssertFalse(outcome.pushed, "dry-run never pushes")
        XCTAssertNil(outcome.pushRemote)
        XCTAssertNil(outcome.pushError)
        XCTAssertEqual(world.git.pushCalls.count, 0)
        XCTAssertEqual(world.git.mergeCalls.count, 0)
    }
}
