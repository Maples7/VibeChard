import XCTest
@testable import VibeChardCore

/// Orchestration tests for `SyncService` driven via `FakeGitClient`
/// and `InMemoryFileSystem`. Covers Q1-Q18 decision branches:
/// dirty / base-unresolved / no-fetch / dry-run / no-op / proceed /
/// rebase-conflict / merge-strategy / upstream-fallback. (#25)
final class SyncServiceTests: XCTestCase {

    private let mainRepo = "/repos/Demo"

    private func makeService(
        seedingTask raw: String,
        seedingState: TaskState,
        fixedDate: Date = Date(timeIntervalSince1970: 1_700_000_100)
    ) -> (SyncService, InMemoryFileSystem, FakeGitClient, FixedClock, TaskName) {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        let task = try! TaskName(raw)
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedDirectory(workspace.vchDir(for: task))
        fs.seedFile(workspace.statePath(for: task),
                    data: try! seedingState.jsonData())
        let git = FakeGitClient()
        git.branches.insert(seedingState.branch)
        let clock = FixedClock(fixedDate)
        let service = SyncService(workspace: workspace, git: git, fs: fs, clock: clock)
        return (service, fs, git, clock, task)
    }

    private func baseState(name: String, baseBranch: String? = "origin/main") -> TaskState {
        TaskState(
            name: name,
            branch: "agent/\(name)",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
            baseRef: "abc123",
            baseBranch: baseBranch
        )
    }

    private func loadState(_ fs: InMemoryFileSystem, _ workspace: Workspace,
                           _ task: TaskName) throws -> TaskState {
        let data = try fs.readFile(at: workspace.statePath(for: task))
        return try TaskState.parse(data)
    }

    // MARK: - happy path: rebase

    func testRebaseSuccessFetchesAndUpdatesLastSync() throws {
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        // Pre-populate planner inputs.
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 2  // ahead
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 3  // behind

        let outcome = try service.sync(task, options: .init())

        XCTAssertEqual(outcome.strategy, .rebase)
        XCTAssertEqual(outcome.baseLabel, "origin/main")
        XCTAssertEqual(outcome.baseSHA, baseSHA)
        XCTAssertEqual(outcome.aheadCount, 2)
        XCTAssertEqual(outcome.behindCount, 3)
        XCTAssertEqual(outcome.appliedCommits, 2)
        XCTAssertFalse(outcome.dryRun)
        XCTAssertTrue(outcome.fetched)
        XCTAssertEqual(outcome.fetchedRemote, "origin")
        XCTAssertFalse(outcome.fetchedFallback)

        // Fetch was called with origin/main split correctly.
        XCTAssertEqual(git.fetchCalls.count, 1)
        XCTAssertEqual(git.fetchCalls[0].remote, "origin")
        XCTAssertEqual(git.fetchCalls[0].branch, "main")

        // Rebase was called inside the task worktree.
        XCTAssertEqual(git.rebaseCalls.count, 1)
        XCTAssertEqual(git.rebaseCalls[0].worktreeCwd, "/repos/Demo-alpha")
        XCTAssertEqual(git.rebaseCalls[0].onto, "origin/main")

        // lastSync persisted with all six fields.
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let state = try loadState(fs, workspace, task)
        let sync = try XCTUnwrap(state.lastSync)
        XCTAssertEqual(sync.baseLabel, "origin/main")
        XCTAssertEqual(sync.baseSHA, baseSHA)
        XCTAssertEqual(sync.strategy, "rebase")
        XCTAssertEqual(sync.appliedCommits, 2)
    }

    // MARK: - merge strategy

    func testMergeStrategyCallsMergeNoFFAndPersistsRecord() throws {
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 1
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 4

        var events: [SyncService.Event] = []
        let outcome = try service.sync(task, options: .init(strategy: .merge)) { events.append($0) }

        XCTAssertEqual(outcome.strategy, .merge)
        XCTAssertEqual(git.rebaseCalls.count, 0)
        XCTAssertEqual(git.mergeCalls.count, 1)
        XCTAssertEqual(git.mergeCalls[0].repoCwd, "/repos/Demo-alpha")
        XCTAssertEqual(git.mergeCalls[0].branch, "origin/main")
        XCTAssertEqual(git.mergeCalls[0].mode, .noFF)
        XCTAssertEqual(git.mergeCalls[0].message,
                       "Merge origin/main into agent/alpha")

        // .merging event fired with the right pair.
        XCTAssertTrue(events.contains {
            if case .merging(let tb, let onto) = $0,
               tb == "agent/alpha", onto == "origin/main" { return true }
            return false
        })

        let workspace = Workspace(mainWorktreePath: mainRepo)
        let state = try loadState(fs, workspace, task)
        XCTAssertEqual(state.lastSync?.strategy, "merge")
    }

    // MARK: - no-op

    func testNoopWritesLastSyncWithZeroCommits() throws {
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 1   // ahead 1
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 0  // behind 0

        var events: [SyncService.Event] = []
        let outcome = try service.sync(task, options: .init()) { events.append($0) }

        XCTAssertEqual(outcome.appliedCommits, 0)
        XCTAssertEqual(outcome.behindCount, 0)
        XCTAssertEqual(git.rebaseCalls.count, 0)  // no rebase invoked
        XCTAssertEqual(git.mergeCalls.count, 0)

        // .alreadyUpToDate event fired (instead of .rebasing).
        XCTAssertTrue(events.contains {
            if case .alreadyUpToDate(let tb, let onto) = $0,
               tb == "agent/alpha", onto == "origin/main" { return true }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .rebasing = $0 { return true } else { return false }
        })

        let workspace = Workspace(mainWorktreePath: mainRepo)
        let sync = try XCTUnwrap(loadState(fs, workspace, task).lastSync)
        XCTAssertEqual(sync.appliedCommits, 0)
        XCTAssertEqual(sync.strategy, "rebase")
    }

    // MARK: - dry-run

    func testDryRunDoesNotRebaseOrWriteState() throws {
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 2
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 3

        var events: [SyncService.Event] = []
        let outcome = try service.sync(task, options: .init(dryRun: true)) { events.append($0) }

        XCTAssertTrue(outcome.dryRun)
        XCTAssertEqual(outcome.appliedCommits, 0)
        XCTAssertEqual(outcome.aheadCount, 2)
        XCTAssertEqual(outcome.behindCount, 3)
        XCTAssertEqual(outcome.fetchedRemote, "origin")  // dry-run still fetches
        XCTAssertTrue(outcome.fetched)
        XCTAssertEqual(git.rebaseCalls.count, 0)
        XCTAssertEqual(git.mergeCalls.count, 0)

        // .dryRunPlan event reports the planner's resolved counts.
        XCTAssertTrue(events.contains {
            if case .dryRunPlan(let strategy, let label, let ahead, let behind) = $0,
               strategy == .rebase, label == "origin/main",
               ahead == 2, behind == 3 { return true }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .rebasing = $0 { return true } else { return false }
        })

        // No state mutation.
        let workspace = Workspace(mainWorktreePath: mainRepo)
        XCTAssertNil(try loadState(fs, workspace, task).lastSync)
    }

    func testDryRunNoOpAlsoSkipsStateWrite() throws {
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 0
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 0

        _ = try service.sync(task, options: .init(dryRun: true))

        let workspace = Workspace(mainWorktreePath: mainRepo)
        XCTAssertNil(try loadState(fs, workspace, task).lastSync)
    }

    // MARK: - --no-fetch

    func testNoFetchSkipsFetchButStillRebases() throws {
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 1
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1

        let outcome = try service.sync(task, options: .init(noFetch: true))

        XCTAssertFalse(outcome.fetched)
        XCTAssertNil(outcome.fetchedRemote)
        XCTAssertEqual(git.fetchCalls.count, 0)
        XCTAssertEqual(git.rebaseCalls.count, 1)
    }

    // MARK: - --onto override

    func testOntoOverrideUsesPassedRefForRebaseButFetchesStateBaseBranch() throws {
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha", baseBranch: "origin/main")
        )
        // The --onto value differs from state.baseBranch — Q12 says we
        // still fetch state.baseBranch's upstream, not --onto's.
        git.revParseByRef["upstream/feature-x"] = "11111111111111111111111111111111ffffffff"
        git.revListCountByRange["11111111111111111111111111111111ffffffff..agent/alpha"] = 1
        git.revListCountByRange["agent/alpha..11111111111111111111111111111111ffffffff"] = 2

        let outcome = try service.sync(task, options: .init(onto: "upstream/feature-x"))

        XCTAssertEqual(outcome.baseLabel, "upstream/feature-x")
        XCTAssertEqual(git.rebaseCalls[0].onto, "upstream/feature-x")
        // Fetch still went to origin/main (per state.baseBranch).
        XCTAssertEqual(git.fetchCalls[0].remote, "origin")
        XCTAssertEqual(git.fetchCalls[0].branch, "main")
    }

    // MARK: - baseLabel promotion (local-branch → remote-tracking ref)

    func testPromotesLocalBaseBranchToRemoteTrackingAfterFetch() throws {
        // Real-world recording: TaskService.newTask captures
        // git.currentBranch() of the main worktree, which is a *local*
        // branch like "main" — never "origin/main". After
        // `git fetch origin main`, only refs/remotes/origin/main moves;
        // local `main` stays at the pre-fetch SHA. SyncService must
        // promote baseLabel to "origin/main" before rev-parse + rebase,
        // otherwise we rebase against stale history.
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha", baseBranch: "main")
        )
        git.upstreamRemoteByBranch["main"] = "origin"
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        // Crucially: the SHA is keyed by the *promoted* label, not "main".
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 2
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1

        let outcome = try service.sync(task, options: .init())

        XCTAssertEqual(outcome.baseLabel, "origin/main",
                       "promotion should advance baseLabel to the remote-tracking ref")
        XCTAssertEqual(outcome.baseSHA, baseSHA)
        XCTAssertEqual(git.rebaseCalls[0].onto, "origin/main",
                       "rebase target must be the freshly-fetched ref, not stale local main")
        // lastSync should record the promoted label so `vch state` reports
        // what we actually rebased onto.
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let sync = try XCTUnwrap(loadState(fs, workspace, task).lastSync)
        XCTAssertEqual(sync.baseLabel, "origin/main")
    }

    func testNoFetchSkipsPromotion() throws {
        // With --no-fetch we trust whatever the user has locally. Don't
        // silently rewrite "main" to "origin/main" — local `main` is
        // exactly the ref the user opted into.
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha", baseBranch: "main")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 0
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1

        let outcome = try service.sync(task, options: .init(noFetch: true))

        XCTAssertEqual(outcome.baseLabel, "main",
                       "no-fetch path should not promote baseLabel")
        XCTAssertEqual(git.rebaseCalls[0].onto, "main")
    }

    func testOntoOverridesPromotion() throws {
        // The promotion only kicks in when --onto is absent. An
        // explicit --onto is the user's escape hatch: pass it through
        // verbatim even though we still fetch state.baseBranch's upstream.
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha", baseBranch: "main")
        )
        git.upstreamRemoteByBranch["main"] = "origin"
        let baseSHA = "11111111111111111111111111111111ffffffff"
        git.revParseByRef["v1.2.3"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 0
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1

        let outcome = try service.sync(task, options: .init(onto: "v1.2.3"))

        XCTAssertEqual(outcome.baseLabel, "v1.2.3")
        XCTAssertEqual(git.rebaseCalls[0].onto, "v1.2.3")
        // Fetch still went to origin/main (state.baseBranch's upstream).
        XCTAssertEqual(git.fetchCalls[0].remote, "origin")
        XCTAssertEqual(git.fetchCalls[0].branch, "main")
    }

    func testOntoRescuesTaskWithoutRecordedBaseBranch() throws {
        // state.baseBranch is nil (e.g. task created off detached HEAD)
        // — without --onto we'd throw syncBaseUnresolved. With --onto,
        // we skip fetch entirely (no recorded branch to refresh) and
        // proceed to rev-parse + rebase the explicit ref.
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha", baseBranch: nil)
        )
        let baseSHA = "11111111111111111111111111111111ffffffff"
        git.revParseByRef["v1.2.3"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 2
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1

        var events: [SyncService.Event] = []
        let outcome = try service.sync(
            task,
            options: .init(onto: "v1.2.3")
        ) { events.append($0) }

        // Fetch was skipped with the .noBaseBranch reason (not
        // .userOptOut — --no-fetch wasn't passed).
        XCTAssertFalse(outcome.fetched)
        XCTAssertNil(outcome.fetchedRemote)
        XCTAssertEqual(git.fetchCalls.count, 0)
        XCTAssertTrue(events.contains {
            if case .fetchSkipped(.noBaseBranch) = $0 { return true } else { return false }
        })
        // The rebase happened against --onto's value.
        XCTAssertEqual(git.rebaseCalls.count, 1)
        XCTAssertEqual(git.rebaseCalls[0].onto, "v1.2.3")
        XCTAssertEqual(outcome.baseLabel, "v1.2.3")
        XCTAssertEqual(outcome.baseSHA, baseSHA)
        // lastSync records --onto's label, not the missing state.baseBranch.
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let recorded = try loadState(fs, workspace, task).lastSync
        XCTAssertEqual(recorded?.baseLabel, "v1.2.3")
        XCTAssertEqual(recorded?.baseSHA, baseSHA)
    }

    // MARK: - upstream fallback

    func testFallsBackToOriginWhenBaseBranchHasNoUpstream() throws {
        // Recorded baseBranch is plain `main` (no remote prefix).
        // upstreamRemoteByBranch is empty → planner falls back to origin
        // and sets fetchedFallback = true.
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha", baseBranch: "main")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 0
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 0

        var events: [SyncService.Event] = []
        let outcome = try service.sync(task, options: .init()) { events.append($0) }

        XCTAssertTrue(outcome.fetchedFallback)
        XCTAssertEqual(outcome.fetchedRemote, "origin")
        XCTAssertEqual(git.fetchCalls[0].remote, "origin")
        XCTAssertEqual(git.fetchCalls[0].branch, "main")
        // .fallbackToOrigin event fired with the recorded baseBranch.
        XCTAssertTrue(events.contains {
            if case .fallbackToOrigin(let bb) = $0, bb == "main" { return true }
            return false
        })
    }

    func testUsesConfiguredUpstreamWhenSet() throws {
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha", baseBranch: "main")
        )
        git.upstreamRemoteByBranch["main"] = "upstream"
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 0
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 0

        let outcome = try service.sync(task, options: .init())

        XCTAssertFalse(outcome.fetchedFallback)
        XCTAssertEqual(outcome.fetchedRemote, "upstream")
        XCTAssertEqual(git.fetchCalls[0].remote, "upstream")
    }

    // MARK: - errors

    func testThrowsBaseUnresolvedWhenStateAndOntoMissing() throws {
        let (service, _, _, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha", baseBranch: nil)
        )
        XCTAssertThrowsError(try service.sync(task, options: .init())) { error in
            guard case let VibeChardError.syncBaseUnresolved(name) = error else {
                return XCTFail("expected syncBaseUnresolved, got \(error)")
            }
            XCTAssertEqual(name, "alpha")
        }
    }

    func testThrowsDirtyWhenWorktreeDirtyAndAllowDirtyFalse() throws {
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        git.dirtyWorktrees.insert("/repos/Demo-alpha")
        XCTAssertThrowsError(try service.sync(task, options: .init())) { error in
            guard case let VibeChardError.syncDirtyWorktree(name, path) = error else {
                return XCTFail("expected syncDirtyWorktree, got \(error)")
            }
            XCTAssertEqual(name, "alpha")
            XCTAssertEqual(path, "/repos/Demo-alpha")
        }
    }

    func testAllowDirtySkipsDirtyPrecheck() throws {
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        git.dirtyWorktrees.insert("/repos/Demo-alpha")
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 1
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1

        XCTAssertNoThrow(try service.sync(task, options: .init(allowDirty: true)))
        XCTAssertEqual(git.rebaseCalls.count, 1)
    }

    func testRebaseConflictWrapsExternalError() throws {
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 1
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1
        git.rebaseError = .externalCommandFailed(
            cmd: "git rebase origin/main",
            exitCode: 128,
            stderr: "CONFLICT (content): Merge conflict in foo.swift"
        )

        XCTAssertThrowsError(try service.sync(task, options: .init())) { error in
            guard case let VibeChardError.syncRebaseConflict(name, path, mode) = error else {
                return XCTFail("expected syncRebaseConflict, got \(error)")
            }
            XCTAssertEqual(name, "alpha")
            XCTAssertEqual(path, "/repos/Demo-alpha")
            XCTAssertEqual(mode, .rebase)
        }
        // No state write on conflict.
        let workspace = Workspace(mainWorktreePath: mainRepo)
        XCTAssertNil(try loadState(fs, workspace, task).lastSync)
    }

    func testMergeConflictWrapsAsMergeMode() throws {
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 1
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1
        git.mergeError = .externalCommandFailed(
            cmd: "git merge --no-ff -m '<msg>' origin/main",
            exitCode: 128,
            stderr: "CONFLICT"
        )

        XCTAssertThrowsError(try service.sync(task, options: .init(strategy: .merge))) { error in
            guard case let VibeChardError.syncRebaseConflict(_, _, mode) = error else {
                return XCTFail("expected syncRebaseConflict, got \(error)")
            }
            XCTAssertEqual(mode, .merge)
        }
    }

    // MARK: - exit-code mapping

    func testSyncErrorExitCodes() {
        let baseUnresolved: VibeChardError = .syncBaseUnresolved(taskName: "alpha")
        XCTAssertEqual(baseUnresolved.exitCode, ExitCode.business)

        let dirty: VibeChardError = .syncDirtyWorktree(
            taskName: "alpha", worktreePath: "/repos/Demo-alpha"
        )
        XCTAssertEqual(dirty.exitCode, ExitCode.business)

        let conflict: VibeChardError = .syncRebaseConflict(
            taskName: "alpha",
            worktreePath: "/repos/Demo-alpha",
            mode: .rebase
        )
        XCTAssertEqual(conflict.exitCode, ExitCode.external)
    }

    // MARK: - progress events

    func testProgressEventsRebasePath() throws {
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 1
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 1

        var events: [SyncService.Event] = []
        _ = try service.sync(task, options: .init()) { events.append($0) }

        // We expect at least: fetching, rebasing.
        XCTAssertTrue(events.contains { if case .fetching(let r, let b) = $0,
                                          r == "origin", b == "main" { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .rebasing(let tb, let onto) = $0,
                                          tb == "agent/alpha", onto == "origin/main" { return true } else { return false } })
    }

    func testProgressEventNoFetchSkipReason() throws {
        let (service, _, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        let baseSHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        git.revParseByRef["origin/main"] = baseSHA
        git.revListCountByRange["\(baseSHA)..agent/alpha"] = 0
        git.revListCountByRange["agent/alpha..\(baseSHA)"] = 0

        var events: [SyncService.Event] = []
        _ = try service.sync(task, options: .init(noFetch: true)) { events.append($0) }
        XCTAssertTrue(events.contains { if case .fetchSkipped(.userOptOut) = $0 { return true } else { return false } })
    }

    // MARK: - state read fault (no auto-rollback contract)

    func testFetchFailureLeavesStateUntouched() throws {
        let (service, fs, git, _, task) = makeService(
            seedingTask: "alpha",
            seedingState: baseState(name: "alpha")
        )
        git.fetchError = .externalCommandFailed(
            cmd: "git fetch origin main",
            exitCode: 128,
            stderr: "fatal: unable to access remote"
        )

        XCTAssertThrowsError(try service.sync(task, options: .init())) { error in
            guard case VibeChardError.externalCommandFailed = error else {
                return XCTFail("expected externalCommandFailed, got \(error)")
            }
        }
        let workspace = Workspace(mainWorktreePath: mainRepo)
        XCTAssertNil(try loadState(fs, workspace, task).lastSync)
    }
}
