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

    // MARK: - simulator-clone cleanup (#61)

    /// Helper: same as `makeHappyPathWorld`, but the seeded
    /// `state.json` includes a `simulator` record so the sim-cleanup
    /// branch in `LandService.land()` has something to delete.
    private func makeWorldWithSimulator(
        cloneUDID: String = "CLONE-UDID",
        cloneName: String = "iPhone 16-vch-alpha"
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
            baseBranch: "main",
            simulator: TaskState.SimulatorRecord(
                cloneUDID: cloneUDID,
                sourceUDID: "SOURCE-UDID",
                name: cloneName,
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
            )
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
        return (workspace, task, fs, git)
    }

    func testLandDeletesSimulatorCloneByDefault() throws {
        // The bug this issue fixes: `vch land` (no flags) used to
        // remove the worktree but leave the per-task simulator clone
        // behind, which then surfaced as an orphan only when the user
        // remembered to run `vch doctor --clean`. This test pins the
        // contract that default `vch land` reaps the clone.
        let world = try makeWorldWithSimulator()
        let simctl = FakeSimctl()
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock(),
            simctl: simctl
        )

        let outcome = try service.land(world.task, options: .init())

        XCTAssertTrue(outcome.merged)
        XCTAssertTrue(outcome.removed, "auto-rm must succeed before sim cleanup")
        XCTAssertTrue(outcome.simRemoved,
                      "default `vch land` must delete the per-task simulator clone")
        XCTAssertEqual(outcome.simName, "iPhone 16-vch-alpha")
        XCTAssertNil(outcome.simRemoveError)
        XCTAssertEqual(simctl.deleteCalls, ["CLONE-UDID"],
                       "simctl.delete must be called with exactly the recorded cloneUDID")
    }

    func testLandKeepSimSkipsSimulatorDeletion() throws {
        // `--keep-sim` is symmetric with `vch rm --keep-sim` and lets
        // the user inspect the simulator state after a merge.
        let world = try makeWorldWithSimulator()
        let simctl = FakeSimctl()
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock(),
            simctl: simctl
        )

        let outcome = try service.land(world.task, options: .init(keepSim: true))

        XCTAssertTrue(outcome.merged)
        XCTAssertTrue(outcome.removed)
        XCTAssertFalse(outcome.simRemoved, "--keep-sim must skip the delete")
        XCTAssertEqual(outcome.simName, "iPhone 16-vch-alpha",
                       "simName surfaces even when we skip the delete, so the CLI can mention what we kept")
        XCTAssertNil(outcome.simRemoveError)
        XCTAssertTrue(simctl.deleteCalls.isEmpty,
                      "simctl.delete must not be called under --keep-sim")
    }

    func testLandKeepFlagAlsoSkipsSimulatorDeletion() throws {
        // `--keep` keeps the entire worktree (and therefore the task
        // is still alive), so the bound simulator is NOT an orphan
        // and must not be deleted out from under the live task.
        let world = try makeWorldWithSimulator()
        let simctl = FakeSimctl()
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock(),
            simctl: simctl
        )

        let outcome = try service.land(world.task, options: .init(keep: true))

        XCTAssertTrue(outcome.merged)
        XCTAssertFalse(outcome.removed,
                       "--keep means the task is still live; sim must stay bound")
        XCTAssertFalse(outcome.simRemoved)
        XCTAssertNil(outcome.simRemoveError)
        XCTAssertTrue(simctl.deleteCalls.isEmpty,
                      "simctl.delete must not run when the task itself is preserved")
    }

    func testLandDryRunNeverTouchesSimctl() throws {
        // Belt-and-suspenders: `--dry-run` reports what *would* happen
        // and must not mutate any external state, simctl included.
        let world = try makeWorldWithSimulator()
        let simctl = FakeSimctl()
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock(),
            simctl: simctl
        )

        let outcome = try service.land(world.task, options: .init(dryRun: true))

        XCTAssertFalse(outcome.merged, "dry-run never merges")
        XCTAssertFalse(outcome.removed)
        XCTAssertFalse(outcome.simRemoved)
        XCTAssertNil(outcome.simRemoveError)
        XCTAssertEqual(outcome.simName, "iPhone 16-vch-alpha",
                       "simName surfaces in dry-run so the CLI can preview what would be reaped")
        XCTAssertTrue(simctl.deleteCalls.isEmpty)
        XCTAssertEqual(world.git.mergeCalls.count, 0)
    }

    func testLandWithNoSimulatorRecordIsNoOp() throws {
        // Tasks that never ran `vch build sim` have no simulator
        // record. Land must be a no-op on the simctl side and emit
        // no error.
        // Use the existing helper that does NOT seed a simulator.
        let world = try makeHappyPathWorld()
        let simctl = FakeSimctl()
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock(),
            simctl: simctl
        )

        let outcome = try service.land(world.task, options: .init())

        XCTAssertTrue(outcome.merged)
        XCTAssertTrue(outcome.removed)
        XCTAssertFalse(outcome.simRemoved)
        XCTAssertNil(outcome.simName,
                     "no recorded simulator → simName is nil")
        XCTAssertNil(outcome.simRemoveError)
        XCTAssertTrue(simctl.deleteCalls.isEmpty)
    }

    func testLandSimDeleteFailureDoesNotRollBackMerge() throws {
        // Mirror of `testPushFailureDoesNotRollBackMerge`: a failing
        // `simctl delete` must surface via `simRemoveError`, leave
        // `merged=true`, and not try to undo the merge or the
        // worktree removal.
        let world = try makeWorldWithSimulator()
        let simctl = FakeSimctl()
        simctl.deleteThrows = .externalCommandFailed(
            cmd: "xcrun simctl delete CLONE-UDID",
            exitCode: 1,
            stderr: "Unable to delete device: device is booted"
        )
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock(),
            simctl: simctl
        )

        let outcome = try service.land(world.task, options: .init())

        XCTAssertTrue(outcome.merged,
                      "merge must still report success — only the sim cleanup failed")
        XCTAssertTrue(outcome.removed,
                      "auto-rm ran before the sim cleanup, so the worktree is still gone")
        XCTAssertFalse(outcome.simRemoved)
        XCTAssertEqual(outcome.simName, "iPhone 16-vch-alpha",
                       "simName must surface on failure so the CLI shows which device vch tried")
        XCTAssertNotNil(outcome.simRemoveError)
        XCTAssertTrue(
            outcome.simRemoveError?.contains("booted") ?? false ||
            outcome.simRemoveError?.contains("simctl delete") ?? false,
            "simRemoveError should embed the underlying failure; got '\(outcome.simRemoveError ?? "nil")'"
        )
        // FakeSimctl throws before appending to deleteCalls, so we
        // can't directly assert which UDID was passed; the populated
        // simRemoveError above is the proof that simctl.delete was
        // attempted.
        XCTAssertEqual(world.git.mergeCalls.count, 1)
    }

    func testLandDoesNotDeleteSimWhenAutoRemoveFailed() throws {
        // If auto-`rm` failed (e.g. dirty task worktree), the
        // worktree is still on disk and the user may retry. Reaping
        // the simulator now would leave them with a half-broken task.
        // Sim cleanup must be gated on a SUCCESSFUL auto-`rm`.
        let world = try makeWorldWithSimulator()
        // Trigger auto-rm failure: removeTask consults statusIsDirty
        // on the task worktree.
        world.git.dirtyWorktrees = [world.workspace.worktreePath(for: world.task)]
        let simctl = FakeSimctl()
        let service = LandService(
            workspace: world.workspace,
            git: world.git,
            fs: world.fs,
            clock: SystemClock(),
            simctl: simctl
        )

        let outcome = try service.land(world.task, options: .init())

        XCTAssertTrue(outcome.merged, "merge succeeded before auto-rm even ran")
        XCTAssertFalse(outcome.removed)
        XCTAssertNotNil(outcome.removeError)
        XCTAssertFalse(outcome.simRemoved,
                       "auto-rm failed; sim must stay bound to the still-alive task")
        XCTAssertNil(outcome.simRemoveError,
                     "we never *attempted* simctl.delete, so there is no error to surface")
        XCTAssertTrue(
            simctl.deleteCalls.isEmpty,
            "simctl.delete must not run when auto-rm failed — leave the sim with the live task"
        )
    }

    // MARK: - adopted auto-rm contract (#98 follow-up)

    /// For a task adopted via `vch new <name> --adopt-current`,
    /// `vch land <name>` must merge the *user's* branch
    /// (`state.branch`, e.g. `feature/codex`) but on success only
    /// scrub vch-owned artefacts (`.vch/`, `.agent-build/`) — never
    /// the user's worktree or branch. Regression guard for the
    /// `vch land` half of the adopt-current contract that PR #98
    /// added on the `vch rm` side.
    func testAutoRmForAdoptedTaskKeepsWorktreeAndBranchIntact() throws {
        let mainRepo = "/repo"
        let adoptedPath = "/Users/me/codex-session"
        let adoptedBranch = "feature/codex"
        let task = try TaskName("codex-task")
        let workspace = Workspace(mainWorktreePath: mainRepo)
            .withWorktreePath(adoptedPath, for: task)

        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(adoptedPath)
        fs.seedDirectory(workspace.vchDir(for: task))
        fs.seedDirectory(workspace.agentBuildDir(for: task))
        let state = TaskState(
            name: "codex-task",
            branch: adoptedBranch,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbee",
            baseBranch: "main",
            worktreeOwnership: .adopted
        )
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())

        let git = FakeGitClient()
        git.branches = ["main", adoptedBranch]
        git.entries = [
            WorktreeEntry(path: mainRepo, branch: "main"),
            WorktreeEntry(path: adoptedPath, branch: adoptedBranch),
        ]
        git.currentBranchByCwd = [mainRepo: "main"]
        git.revListCountByRange["main..\(adoptedBranch)"] = 1
        git.diffNamesByRange["main..\(adoptedBranch)"] = ["src/foo.swift"]
        git.lastSubjectByBranch[adoptedBranch] = "feat: codex spike"

        let service = LandService(workspace: workspace, git: git, fs: fs, clock: SystemClock())
        let outcome = try service.land(task, options: .init())

        // Merge must reference the adopted branch and use it in the message (#98).
        XCTAssertEqual(git.mergeCalls.count, 1)
        XCTAssertEqual(git.mergeCalls.first?.branch, adoptedBranch,
                       "merge target must be state.branch, not agent/<task>")
        XCTAssertEqual(git.mergeCalls.first?.message,
                       "Merge \(adoptedBranch): feat: codex spike",
                       "merge commit message must use state.branch")

        // Auto-rm path: outcome.removed reports cleanup ran, but for an
        // adopted task no worktree-remove and no branch-delete may have
        // been issued — only the vch-owned scratch must be gone.
        XCTAssertTrue(outcome.merged)
        XCTAssertTrue(outcome.removed,
                      "removed=true for adopted means vch artefacts scrubbed (not the worktree itself)")
        XCTAssertNil(outcome.removeError)
        XCTAssertEqual(git.removeCalls.count, 0,
                       "must not git worktree remove an adopted worktree")
        XCTAssertEqual(git.branchDeleteCalls.count, 0,
                       "must not delete the user's branch under an adopted task")
        // Adopted worktree itself is untouched.
        XCTAssertTrue(fs.directoryExists(at: adoptedPath),
                      "the user-owned worktree must remain on disk")
        // vch-owned scratch is gone.
        XCTAssertFalse(fs.directoryExists(at: workspace.vchDir(for: task)))
        XCTAssertFalse(fs.directoryExists(at: workspace.agentBuildDir(for: task)))
    }

    // MARK: - #99 multi-platform binding cleanup

    /// Seed a world where the task owns BOTH an iOS and a watchOS
    /// simulator clone (via the new `simulators` list field). Used
    /// by the multi-binding land tests below.
    private func makeWorldWithTwoSimulators()
        throws -> (workspace: Workspace, task: TaskName, fs: InMemoryFileSystem, git: FakeGitClient)
    {
        let mainRepo = "/repo"
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let task = try TaskName("alpha")
        let wtPath = workspace.worktreePath(for: task)

        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(wtPath)
        fs.seedDirectory(workspace.vchDir(for: task))
        var state = TaskState(
            name: "alpha",
            branch: "agent/alpha",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbee",
            baseBranch: "main"
        )
        state.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "IOS-CLONE",
                sourceUDID: "IOS-TPL",
                name: "iPhone 16-vch-alpha",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
            ),
            TaskState.SimulatorRecord(
                cloneUDID: "WATCH-CLONE",
                sourceUDID: "WATCH-TPL",
                name: "Apple Watch Series 10-vch-alpha",
                templateName: "Apple Watch Series 10 (46mm)",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"
            ),
        ])
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
        return (workspace, task, fs, git)
    }

    func testLandDeletesEveryBindingOnMultiPlatformTask() throws {
        // #99: a task with multiple platform clones (iOS + watchOS)
        // must have all of them reaped on a successful `vch land`.
        // Pre-#99 only the legacy single `simulator` field was
        // consulted, so the second binding silently leaked.
        let world = try makeWorldWithTwoSimulators()
        let simctl = FakeSimctl()
        let service = LandService(
            workspace: world.workspace, git: world.git,
            fs: world.fs, clock: SystemClock(), simctl: simctl
        )
        let outcome = try service.land(world.task, options: .init())

        XCTAssertTrue(outcome.simRemoved)
        XCTAssertEqual(Set(simctl.deleteCalls),
                       Set(["IOS-CLONE", "WATCH-CLONE"]),
                       "both clones must be reaped, order doesn't matter")
        XCTAssertEqual(outcome.simName,
                       "iPhone 16-vch-alpha, Apple Watch Series 10-vch-alpha",
                       "simName joins every reaped clone so the CLI can list them")
        XCTAssertNil(outcome.simRemoveError)
    }

    func testLandPartialDeleteFailureRetriesEveryBinding() throws {
        // First simctl.delete fails, but vch must continue and
        // attempt the second one. simRemoved=false because at least
        // one failed; simRemoveError carries the underlying detail.
        let world = try makeWorldWithTwoSimulators()
        let simctl = FakeSimctl()
        // Fail only for the first UDID; the second one succeeds.
        simctl.deleteThrowsByUDID["IOS-CLONE"] = .externalCommandFailed(
            cmd: "xcrun simctl delete IOS-CLONE",
            exitCode: 1,
            stderr: "Unable to delete device: still booted"
        )
        let service = LandService(
            workspace: world.workspace, git: world.git,
            fs: world.fs, clock: SystemClock(), simctl: simctl
        )
        let outcome = try service.land(world.task, options: .init())

        XCTAssertTrue(outcome.merged)
        XCTAssertTrue(outcome.removed)
        XCTAssertFalse(outcome.simRemoved,
                       "partial failure → simRemoved must be false")
        XCTAssertTrue(simctl.deleteCalls.contains("WATCH-CLONE"),
                      "second binding must still be attempted even after the first one failed")
        XCTAssertNotNil(outcome.simRemoveError)
        XCTAssertTrue(
            outcome.simRemoveError?.contains("IOS-CLONE") ?? false ||
            outcome.simRemoveError?.contains("iPhone 16-vch-alpha") ?? false,
            "simRemoveError must mention the failing binding: '\(outcome.simRemoveError ?? "nil")'"
        )
    }
}
