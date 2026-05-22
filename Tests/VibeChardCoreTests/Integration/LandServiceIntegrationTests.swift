import XCTest
@testable import VibeChardCore

/// End-to-end test of `LandService` with a real `/usr/bin/git` and a
/// real `FileManager`-backed filesystem in a unique temp directory.
/// Skipped automatically if git is not on disk (e.g. on minimal CI).
/// Covers the acceptance criteria from #7. (#7)
final class LandServiceIntegrationTests: XCTestCase {

    private var rootDir: URL!
    private var gitEnv: [String: String]!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                      "/usr/bin/git not available")
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vch-land-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        gitEnv = [
            "GIT_AUTHOR_NAME": "vch test",
            "GIT_AUTHOR_EMAIL": "vch@test.local",
            "GIT_COMMITTER_NAME": "vch test",
            "GIT_COMMITTER_EMAIL": "vch@test.local",
            "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": rootDir.path,
            "XDG_CONFIG_HOME": rootDir.appendingPathComponent("xdg").path,
        ]
    }

    override func tearDownWithError() throws {
        if let rootDir, FileManager.default.fileExists(atPath: rootDir.path) {
            try? FileManager.default.removeItem(at: rootDir)
        }
    }

    private func makeRepo() throws -> Workspace {
        let repoPath = rootDir.appendingPathComponent("Repo").path
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)

        let runner = DiskProcessRunner()
        try requireSuccess(runner.run("/usr/bin/git", args: ["init", "-q", "-b", "main"], cwd: repoPath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git", args: ["config", "commit.gpgsign", "false"], cwd: repoPath, env: gitEnv))
        try "hello".write(toFile: "\(repoPath)/README.md", atomically: true, encoding: .utf8)
        try requireSuccess(runner.run("/usr/bin/git", args: ["add", "README.md"], cwd: repoPath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git", args: ["commit", "-q", "-m", "initial"], cwd: repoPath, env: gitEnv))

        return Workspace(mainWorktreePath: repoPath)
    }

    private func requireSuccess(_ result: ProcessResult, file: StaticString = #filePath, line: UInt = #line) throws {
        if !result.succeeded {
            XCTFail("command failed: \(result.stderr)", file: file, line: line)
            throw VibeChardError.externalCommandFailed(cmd: "git", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Helper: write a file in a worktree, stage and commit it.
    private func commitFile(workspace: Workspace, worktreePath: String, name: String, contents: String, message: String) throws {
        try contents.write(toFile: "\(worktreePath)/\(name)", atomically: true, encoding: .utf8)
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run("/usr/bin/git", args: ["add", name], cwd: worktreePath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git", args: ["commit", "-q", "-m", message], cwd: worktreePath, env: gitEnv))
    }

    private func makeServices(workspace: Workspace) -> (TaskService, LandService) {
        let git = DiskGitClient()
        let fs = DiskFileSystem()
        let clock = SystemClock()
        return (
            TaskService(workspace: workspace, git: git, fs: fs, clock: clock),
            LandService(workspace: workspace, git: git, fs: fs, clock: clock)
        )
    }

    /// Replace `DiskProcessRunner` with one that injects the test git env.
    /// `DiskGitClient` already shells out via `DiskProcessRunner`, which
    /// inherits the parent process's env. Tests run inside Xcode's
    /// process, which has a real $HOME — sufficient for git here. The
    /// override is needed only for the manual git invocations above.
    private func newTaskWithBranch(
        _ name: String,
        baseBranch: String = "main",
        workspace: Workspace
    ) throws -> (TaskName, String) {
        let task = try TaskName(name)
        let (taskService, _) = makeServices(workspace: workspace)
        let path = try taskService.newTask(task)
        return (task, path)
    }

    // MARK: - happy paths

    func testCleanLandNoFFCreatesMergeCommitAndRemovesWorktree() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("alpha", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// new feature\n",
                       message: "feat: add Foo")

        let (_, landService) = makeServices(workspace: workspace)
        let outcome = try landService.land(task, options: .init())

        XCTAssertTrue(outcome.merged)
        XCTAssertEqual(outcome.into, "main")
        XCTAssertEqual(outcome.strategy, .noFF)
        XCTAssertEqual(outcome.message, "Merge agent/alpha: feat: add Foo")
        XCTAssertTrue(outcome.removed)
        XCTAssertNil(outcome.removeError)

        // Verify there's a merge commit on main with the right subject.
        let runner = DiskProcessRunner()
        let log = try runner.run("/usr/bin/git",
                                  args: ["log", "--format=%s", "-n", "1"],
                                  cwd: workspace.mainWorktreePath)
        XCTAssertEqual(log.stdoutTrimmed, "Merge agent/alpha: feat: add Foo")

        // Worktree gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: taskPath))

        // Branch gone.
        let exists = try DiskGitClient().branchExists(repoCwd: workspace.mainWorktreePath, name: task.branchName)
        XCTAssertFalse(exists)
    }

    func testCustomMessageOverridesDefault() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("beta", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// b\n",
                       message: "wip")

        let (_, landService) = makeServices(workspace: workspace)
        let outcome = try landService.land(task, options: .init(message: "Land beta refactor"))

        XCTAssertEqual(outcome.message, "Land beta refactor")
        let runner = DiskProcessRunner()
        let log = try runner.run("/usr/bin/git",
                                  args: ["log", "--format=%s", "-n", "1"],
                                  cwd: workspace.mainWorktreePath)
        XCTAssertEqual(log.stdoutTrimmed, "Land beta refactor")
    }

    func testKeepFlagPreservesWorktree() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("gamma", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// g\n",
                       message: "chore: stub")

        let (_, landService) = makeServices(workspace: workspace)
        let outcome = try landService.land(task, options: .init(keep: true))

        XCTAssertTrue(outcome.merged)
        XCTAssertFalse(outcome.removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskPath))
    }

    func testDryRunDoesNotMergeOrRemove() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("delta", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// d\n",
                       message: "feat: dry test")

        let runner = DiskProcessRunner()
        let initialHead = try runner.run("/usr/bin/git",
                                          args: ["rev-parse", "HEAD"],
                                          cwd: workspace.mainWorktreePath).stdoutTrimmed

        let (_, landService) = makeServices(workspace: workspace)
        let outcome = try landService.land(task, options: .init(dryRun: true))

        XCTAssertFalse(outcome.merged)
        XCTAssertFalse(outcome.removed)
        XCTAssertEqual(outcome.message, "Merge agent/delta: feat: dry test")
        XCTAssertEqual(outcome.touchedPaths, ["feature.swift"])

        let postHead = try runner.run("/usr/bin/git",
                                       args: ["rev-parse", "HEAD"],
                                       cwd: workspace.mainWorktreePath).stdoutTrimmed
        XCTAssertEqual(initialHead, postHead, "dry-run must not modify HEAD")
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskPath), "dry-run must not remove worktree")
    }

    func testSquashStrategyProducesSquashedCommit() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("epsilon", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "first.swift", contents: "// 1\n", message: "step 1")
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "second.swift", contents: "// 2\n", message: "step 2: final")

        let (_, landService) = makeServices(workspace: workspace)
        let outcome = try landService.land(task, options: .init(strategy: .squash))

        XCTAssertTrue(outcome.merged)
        XCTAssertEqual(outcome.strategy, .squash)
        // Default subject is the most recent non-merge commit's subject.
        XCTAssertEqual(outcome.message, "Merge agent/epsilon: step 2: final")

        let runner = DiskProcessRunner()
        // After --squash there should be exactly one new commit on main,
        // not a merge commit. Check `git log -1 --format=%P` returns
        // exactly one parent.
        let parents = try runner.run("/usr/bin/git",
                                       args: ["log", "-1", "--format=%P"],
                                       cwd: workspace.mainWorktreePath).stdoutTrimmed
        XCTAssertFalse(parents.contains(" "), "squash commit must have a single parent")
    }

    // MARK: - aborts

    func testRefusesNoOpMerge() throws {
        let workspace = try makeRepo()
        let (task, _) = try newTaskWithBranch("zeta", workspace: workspace)
        // No commits on the task branch — task branch == main HEAD.

        let (_, landService) = makeServices(workspace: workspace)
        XCTAssertThrowsError(try landService.land(task, options: .init())) { error in
            guard case .landNoOp = error as? VibeChardError else {
                return XCTFail("expected landNoOp, got \(error)")
            }
        }
    }

    func testRefusesWhenMainHasOverlappingDirtyPaths() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("eta", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "shared.swift", contents: "// task\n",
                       message: "feat: edit shared.swift")

        // Now dirty `shared.swift` in the main worktree (uncommitted).
        try "// dirty\n".write(
            toFile: "\(workspace.mainWorktreePath)/shared.swift",
            atomically: true, encoding: .utf8
        )

        let (_, landService) = makeServices(workspace: workspace)
        XCTAssertThrowsError(try landService.land(task, options: .init())) { error in
            guard case let .landMergeOverlap(paths) = error as? VibeChardError else {
                return XCTFail("expected landMergeOverlap, got \(error)")
            }
            XCTAssertTrue(paths.contains("shared.swift"))
        }
    }

    func testAllowsLandWhenDirtyPathsDoNotOverlap() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("theta", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// t\n",
                       message: "feat: theta")

        // Dirty file in main, but not in the task's diff.
        try "scratch\n".write(
            toFile: "\(workspace.mainWorktreePath)/notes.txt",
            atomically: true, encoding: .utf8
        )

        let (_, landService) = makeServices(workspace: workspace)
        let outcome = try landService.land(task, options: .init())
        XCTAssertTrue(outcome.merged)
    }

    func testAllowDirtyFlagBypassesOverlapRefusal() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("iota", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "shared.swift", contents: "// task\n",
                       message: "feat: edit shared")

        try "// dirty\n".write(
            toFile: "\(workspace.mainWorktreePath)/shared.swift",
            atomically: true, encoding: .utf8
        )

        let (_, landService) = makeServices(workspace: workspace)
        // The merge will likely fail anyway because git refuses to
        // merge with overwriting changes; we only care that vch's
        // pre-flight didn't reject it. Distinguish landMergeOverlap
        // from externalCommandFailed via a switch.
        do {
            _ = try landService.land(task, options: .init(allowDirty: true))
        } catch let error as VibeChardError {
            switch error {
            case .landMergeOverlap:
                XCTFail("--allow-dirty should bypass mergeOverlap pre-flight")
            case .externalCommandFailed:
                // Expected: git itself refuses the unsafe merge.
                break
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMergeConflictReportsConflictedFilesAndLeavesWorktreeForRecovery() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("rho", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "README.md", contents: "task change\n",
                       message: "feat: task edit")
        try commitFile(workspace: workspace, worktreePath: workspace.mainWorktreePath,
                       name: "README.md", contents: "main change\n",
                       message: "chore: main edit")

        let (_, landService) = makeServices(workspace: workspace)
        XCTAssertThrowsError(try landService.land(task, options: .init())) { error in
            guard case let VibeChardError.landMergeConflict(name, path, paths) = error else {
                return XCTFail("expected landMergeConflict, got \(error)")
            }
            XCTAssertEqual(name, "rho")
            XCTAssertEqual(path, workspace.mainWorktreePath)
            XCTAssertEqual(paths, ["README.md"])
            XCTAssertTrue(String(describing: error).contains("git commit --no-edit"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: taskPath),
                      "conflict recovery needs the task worktree to remain available")
        let runner = DiskProcessRunner()
        let status = try runner.run("/usr/bin/git",
                                    args: ["status", "--porcelain"],
                                    cwd: workspace.mainWorktreePath,
                                    env: gitEnv)
        XCTAssertTrue(status.stdout.contains("UU README.md"),
                      "base worktree should remain in the unresolved merge state")
    }

    func testRefusesWhenTaskBranchMissing() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("kappa", workspace: workspace)
        // Remove the worktree directly via git, then delete the branch
        // — simulating a user who deleted things outside vch and left
        // `state.json` stale.
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run("/usr/bin/git",
                                       args: ["worktree", "remove", "--force", taskPath],
                                       cwd: workspace.mainWorktreePath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git",
                                       args: ["branch", "-D", task.branchName],
                                       cwd: workspace.mainWorktreePath, env: gitEnv))

        let (_, landService) = makeServices(workspace: workspace)
        XCTAssertThrowsError(try landService.land(task, options: .init())) { error in
            // After deleting the worktree, state.json is also gone, so
            // we hit `taskNotFound` first. If state.json had been
            // preserved (e.g. user deleted the branch but left the
            // worktree), we'd hit `landBranchMissing`. Either is OK.
            switch error as? VibeChardError {
            case .landBranchMissing, .taskNotFound, .stateFileMissing:
                break
            default:
                XCTFail("expected landBranchMissing / taskNotFound / stateFileMissing, got \(error)")
            }
        }
    }

    func testRefusesWhenMainOnDifferentBranch() throws {
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("lambda", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// l\n",
                       message: "feat: lambda")

        // Create + switch to a sibling branch on main.
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run("/usr/bin/git",
                                       args: ["switch", "-c", "develop"],
                                       cwd: workspace.mainWorktreePath, env: gitEnv))

        let (_, landService) = makeServices(workspace: workspace)
        XCTAssertThrowsError(try landService.land(task, options: .init())) { error in
            guard case let .landMainNotOnInto(currentBranch, want) = error as? VibeChardError else {
                return XCTFail("expected landMainNotOnInto, got \(error)")
            }
            XCTAssertEqual(currentBranch, "develop")
            XCTAssertEqual(want, "main")
        }
    }

    func testLandIntoExplicitBranchWorks() throws {
        let workspace = try makeRepo()
        // Set up: main HEAD becomes a "develop" branch named main; user
        // has switched. Task forks from main.
        let (task, taskPath) = try newTaskWithBranch("mu", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// m\n",
                       message: "feat: mu")

        // Create develop pointing at main, switch to it, then land --into develop.
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run("/usr/bin/git",
                                       args: ["switch", "-c", "develop"],
                                       cwd: workspace.mainWorktreePath, env: gitEnv))

        let (_, landService) = makeServices(workspace: workspace)
        let outcome = try landService.land(task, options: .init(into: "develop"))
        XCTAssertTrue(outcome.merged)
        XCTAssertEqual(outcome.into, "develop")
    }

    func testRecordedBaseBranchIsPersistedByVchNew() throws {
        let workspace = try makeRepo()
        let (task, _) = try newTaskWithBranch("nu", workspace: workspace)
        let (taskService, _) = makeServices(workspace: workspace)
        let state = try taskService.stateForTask(task)
        XCTAssertEqual(state.baseBranch, "main",
                       "vch new must record the main worktree's branch as baseBranch")
    }

    func testFfOnlyStrategyProducesFastForwardCommit() throws {
        // `--ff-only` turns the merge into a fast-forward. main moves
        // to the task branch's HEAD; no merge commit is created.
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("xi", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// xi\n",
                       message: "feat: xi")

        let runner = DiskProcessRunner()
        let taskHead = try runner.run("/usr/bin/git",
                                       args: ["rev-parse", task.branchName],
                                       cwd: workspace.mainWorktreePath,
                                       env: gitEnv).stdoutTrimmed

        let (_, landService) = makeServices(workspace: workspace)
        let outcome = try landService.land(task, options: .init(strategy: .ffOnly))

        XCTAssertTrue(outcome.merged)
        XCTAssertEqual(outcome.strategy, .ffOnly)
        XCTAssertTrue(outcome.removed)

        // After fast-forward, main HEAD == task HEAD and the new HEAD
        // has exactly one parent (the previous main HEAD), confirming
        // no merge commit was created.
        let mainHead = try runner.run("/usr/bin/git",
                                       args: ["rev-parse", "HEAD"],
                                       cwd: workspace.mainWorktreePath,
                                       env: gitEnv).stdoutTrimmed
        XCTAssertEqual(mainHead, taskHead, "ff-only must move main HEAD to task HEAD")

        let parents = try runner.run("/usr/bin/git",
                                      args: ["log", "-1", "--format=%P"],
                                      cwd: workspace.mainWorktreePath,
                                      env: gitEnv).stdoutTrimmed
        XCTAssertFalse(parents.contains(" "),
                       "ff-only must not create a merge commit (single parent expected)")
    }

    func testFfOnlyRefusesWhenFastForwardImpossible() throws {
        // Diverge: add a commit to main *after* creating the task
        // branch. Now main is no longer an ancestor of task → git
        // refuses --ff-only with a non-zero exit, which surfaces as
        // `externalCommandFailed` from LandService.
        let workspace = try makeRepo()
        let (task, taskPath) = try newTaskWithBranch("omicron", workspace: workspace)
        try commitFile(workspace: workspace, worktreePath: taskPath,
                       name: "feature.swift", contents: "// o\n",
                       message: "feat: o")
        // Add a divergent commit to main.
        try commitFile(workspace: workspace, worktreePath: workspace.mainWorktreePath,
                       name: "MAIN.md", contents: "main moved\n",
                       message: "chore: main moves")

        let (_, landService) = makeServices(workspace: workspace)
        XCTAssertThrowsError(try landService.land(task, options: .init(strategy: .ffOnly))) { error in
            guard case .externalCommandFailed = error as? VibeChardError else {
                return XCTFail("expected externalCommandFailed (git refuses --ff-only), got \(error)")
            }
        }
        // Worktree must still be present — LandService aborts auto-rm
        // when the merge itself fails.
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskPath))
    }
}
