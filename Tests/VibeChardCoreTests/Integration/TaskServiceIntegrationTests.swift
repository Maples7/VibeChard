import XCTest
@testable import VibeChardCore

/// End-to-end test of `TaskService` with a real `/usr/bin/git` and a
/// real `FileManager`-backed filesystem in a unique temp directory.
/// Skipped automatically if git is not on disk (e.g. on minimal CI).
final class TaskServiceIntegrationTests: XCTestCase {

    private var rootDir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                      "/usr/bin/git not available")
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vch-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDir, FileManager.default.fileExists(atPath: rootDir.path) {
            try? FileManager.default.removeItem(at: rootDir)
        }
    }

    /// Initialize a fresh repo at `<rootDir>/Repo` with one commit so
    /// `git worktree add` has something to branch from.
    private func makeRepo() throws -> Workspace {
        let repoPath = rootDir.appendingPathComponent("Repo").path
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)

        let runner = DiskProcessRunner()
        let env: [String: String] = [
            "GIT_AUTHOR_NAME": "vch test",
            "GIT_AUTHOR_EMAIL": "vch@test.local",
            "GIT_COMMITTER_NAME": "vch test",
            "GIT_COMMITTER_EMAIL": "vch@test.local",
            // Avoid loading the user's global config (e.g. signing keys).
            "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": rootDir.path,
            "XDG_CONFIG_HOME": rootDir.appendingPathComponent("xdg").path,
        ]
        try requireSuccess(runner.run("/usr/bin/git", args: ["init", "-q", "-b", "main"], cwd: repoPath, env: env))
        // Disable signing/hooks/etc. by writing a minimal repo config.
        try requireSuccess(runner.run("/usr/bin/git", args: ["config", "commit.gpgsign", "false"], cwd: repoPath, env: env))
        try "hello".write(toFile: "\(repoPath)/README.md", atomically: true, encoding: .utf8)
        try requireSuccess(runner.run("/usr/bin/git", args: ["add", "README.md"], cwd: repoPath, env: env))
        try requireSuccess(runner.run("/usr/bin/git", args: ["commit", "-q", "-m", "initial"], cwd: repoPath, env: env))

        return Workspace(mainWorktreePath: repoPath)
    }

    private func requireSuccess(_ result: ProcessResult, file: StaticString = #filePath, line: UInt = #line) throws {
        if !result.succeeded {
            XCTFail("command failed: \(result.stderr)", file: file, line: line)
            throw VibeChardError.externalCommandFailed(cmd: "git", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private func makeService(workspace: Workspace) -> TaskService {
        TaskService(
            workspace: workspace,
            git: DiskGitClient(),
            fs: DiskFileSystem(),
            clock: SystemClock()
        )
    }

    // MARK: - Tests

    func testNewListPathRemoveHappyPath() throws {
        let workspace = try makeRepo()
        let service = makeService(workspace: workspace)
        let task = try TaskName("alpha")

        // new
        let path = try service.newTask(task)
        XCTAssertEqual(path, "\(workspace.parentDirectory)/Repo-alpha")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/.vch/state.json"))

        // path
        XCTAssertEqual(try service.pathForTask(task), path)

        // list
        let summaries = try service.listTasks()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.name, "alpha")
        XCTAssertEqual(summaries.first?.branch, "agent/alpha")
        XCTAssertNotNil(summaries.first?.createdAt)

        // remove
        try service.removeTask(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let listAfter = try service.listTasks()
        XCTAssertEqual(listAfter.count, 0)
    }

    func testNewRefusesIfBranchExistsAlready() throws {
        let workspace = try makeRepo()
        let service = makeService(workspace: workspace)
        // Pre-create branch.
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run("/usr/bin/git", args: ["branch", "agent/alpha"], cwd: workspace.mainWorktreePath))

        XCTAssertThrowsError(try service.newTask(TaskName("alpha"))) { error in
            guard case VibeChardError.worktreeAlreadyExists = error else {
                return XCTFail("expected worktreeAlreadyExists, got \(error)")
            }
        }
    }

    func testRemoveRefusesDirtyWorktree() throws {
        let workspace = try makeRepo()
        let service = makeService(workspace: workspace)
        let task = try TaskName("alpha")
        let path = try service.newTask(task)

        // Make the worktree dirty by adding an untracked file.
        try "x".write(toFile: "\(path)/dirty.txt", atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.removeTask(task)) { error in
            guard case VibeChardError.dirtyWorktree = error else {
                return XCTFail("expected dirtyWorktree, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // With allowDirty: removes worktree and branch (branch is unmerged
        // because we made a commit on it... but we haven't, so it should
        // actually still be considered fully merged → branch -d succeeds).
        try service.removeTask(task, options: .forceDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRemoveStopsAtUnmergedBranchWithoutDoubleForce() throws {
        let workspace = try makeRepo()
        let service = makeService(workspace: workspace)
        let task = try TaskName("alpha")
        let path = try service.newTask(task)

        // Add a commit on the agent branch so it's unmerged relative to main.
        let runner = DiskProcessRunner()
        let env: [String: String] = [
            "GIT_AUTHOR_NAME": "vch test", "GIT_AUTHOR_EMAIL": "vch@test.local",
            "GIT_COMMITTER_NAME": "vch test", "GIT_COMMITTER_EMAIL": "vch@test.local",
            "GIT_CONFIG_NOSYSTEM": "1", "HOME": rootDir.path,
        ]
        try "y".write(toFile: "\(path)/feature.txt", atomically: true, encoding: .utf8)
        try requireSuccess(runner.run("/usr/bin/git", args: ["add", "feature.txt"], cwd: path, env: env))
        try requireSuccess(runner.run("/usr/bin/git", args: ["commit", "-q", "-m", "feature"], cwd: path, env: env))

        // Default: branch is unmerged, so the (-d) delete should fail and
        // we surface unmergedBranch. The worktree itself is gone.
        XCTAssertThrowsError(try service.removeTask(task)) { error in
            guard case VibeChardError.unmergedBranch = error else {
                return XCTFail("expected unmergedBranch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        // Branch should still exist.
        let exists = try DiskGitClient().branchExists(repoCwd: workspace.mainWorktreePath, name: "agent/alpha")
        XCTAssertTrue(exists)

        // Recovery: allowUnmergedBranch should force-delete it.
        // The worktree is already gone, so call git directly through service:
        // but service.removeTask requires the worktree to exist. Use the
        // public service hook only when valid; here we exercise force-delete
        // directly through GitClient as the recovery path the user has via
        // `vch repair` + manual git in v1.
        try DiskGitClient().branchDeleteForce(repoCwd: workspace.mainWorktreePath, name: "agent/alpha")
        let stillExists = try DiskGitClient().branchExists(repoCwd: workspace.mainWorktreePath, name: "agent/alpha")
        XCTAssertFalse(stillExists)
    }

    func testRepairFlagsMissingState() throws {
        let workspace = try makeRepo()
        let service = makeService(workspace: workspace)
        let task = try TaskName("alpha")
        let path = try service.newTask(task)

        // Corrupt state.json by deleting it.
        try FileManager.default.removeItem(atPath: "\(path)/.vch/state.json")

        let report = try service.repair()
        XCTAssertTrue(report.checkedTasks.contains("alpha"))
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertTrue(report.problems[0].contains("missing"))
    }
}
