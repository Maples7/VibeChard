import XCTest
@testable import VibeChardCore

/// End-to-end test of `SyncService` driving `DiskGitClient` against a
/// real `/usr/bin/git` and a real bare "remote". Skipped automatically
/// if git is not on disk (e.g. minimal CI). Exercises the four new
/// `DiskGitClient` methods (`fetch`, `rebase`, `upstreamRemote`,
/// `revParse`) plus the `SyncService` happy-path / no-op / conflict
/// branches against actual git output. (#25)
final class SyncServiceIntegrationTests: XCTestCase {

    private var rootDir: URL!
    private var gitEnv: [String: String]!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                      "/usr/bin/git not available")
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vch-sync-it-\(UUID().uuidString)")
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

    // MARK: - fixture helpers

    /// Builds a bare "remote" + working clone with one initial commit on
    /// `main`. Returns the workspace pointing at the working clone.
    private func makeRemoteAndClone() throws -> Workspace {
        let runner = DiskProcessRunner()

        let remotePath = rootDir.appendingPathComponent("Origin.git").path
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["init", "-q", "--bare", "-b", "main", remotePath],
                                      cwd: rootDir.path, env: gitEnv))

        let repoPath = rootDir.appendingPathComponent("Repo").path
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["clone", "-q", remotePath, repoPath],
                                      cwd: rootDir.path, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["config", "commit.gpgsign", "false"],
                                      cwd: repoPath, env: gitEnv))
        try "hello\n".write(toFile: "\(repoPath)/README.md", atomically: true, encoding: .utf8)
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["add", "README.md"],
                                      cwd: repoPath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["commit", "-q", "-m", "initial"],
                                      cwd: repoPath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["push", "-q", "-u", "origin", "main"],
                                      cwd: repoPath, env: gitEnv))

        return Workspace(mainWorktreePath: repoPath)
    }

    /// Push a new commit on `main` from a *second* clone, simulating a
    /// coworker advancing the upstream while we work on `agent/<name>`.
    /// Returns the SHA of the new commit.
    @discardableResult
    private func advanceRemoteMain(filename: String, contents: String, message: String) throws -> String {
        let runner = DiskProcessRunner()
        let remotePath = rootDir.appendingPathComponent("Origin.git").path
        let pubPath = rootDir.appendingPathComponent("Publisher-\(UUID().uuidString)").path
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["clone", "-q", remotePath, pubPath],
                                      cwd: rootDir.path, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["config", "commit.gpgsign", "false"],
                                      cwd: pubPath, env: gitEnv))
        try contents.write(toFile: "\(pubPath)/\(filename)", atomically: true, encoding: .utf8)
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["add", filename],
                                      cwd: pubPath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["commit", "-q", "-m", message],
                                      cwd: pubPath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["push", "-q", "origin", "main"],
                                      cwd: pubPath, env: gitEnv))
        let head = try runner.run("/usr/bin/git",
                                  args: ["rev-parse", "HEAD"],
                                  cwd: pubPath, env: gitEnv).stdoutTrimmed
        return head
    }

    private func commitInTaskWorktree(_ taskPath: String, filename: String,
                                      contents: String, message: String) throws {
        try contents.write(toFile: "\(taskPath)/\(filename)", atomically: true, encoding: .utf8)
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["add", filename],
                                      cwd: taskPath, env: gitEnv))
        try requireSuccess(runner.run("/usr/bin/git",
                                      args: ["commit", "-q", "-m", message],
                                      cwd: taskPath, env: gitEnv))
    }

    private func makeTask(_ raw: String, workspace: Workspace) throws -> (TaskName, String) {
        let task = try TaskName(raw)
        let taskService = TaskService(workspace: workspace,
                                      git: DiskGitClient(),
                                      fs: DiskFileSystem(),
                                      clock: SystemClock())
        let path = try taskService.newTask(task)
        return (task, path)
    }

    private func makeSyncService(_ workspace: Workspace) -> SyncService {
        SyncService(workspace: workspace,
                    git: DiskGitClient(),
                    fs: DiskFileSystem(),
                    clock: SystemClock())
    }

    private func requireSuccess(_ result: ProcessResult,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        if !result.succeeded {
            XCTFail("command failed: \(result.stderr)", file: file, line: line)
            throw VibeChardError.externalCommandFailed(cmd: "git",
                                                       exitCode: result.exitCode,
                                                       stderr: result.stderr)
        }
    }

    // MARK: - happy path: rebase against a moved upstream

    func testRebasesAgainstMovedRemoteMain() throws {
        let workspace = try makeRemoteAndClone()
        let (task, taskPath) = try makeTask("alpha", workspace: workspace)

        // Task adds its own commit.
        try commitInTaskWorktree(taskPath, filename: "feature.swift",
                                 contents: "// alpha\n",
                                 message: "feat: alpha")

        // Coworker advances origin/main.
        let movedSHA = try advanceRemoteMain(filename: "co.swift",
                                             contents: "// coworker\n",
                                             message: "feat: coworker")

        // Sync.
        let outcome = try makeSyncService(workspace).sync(task, options: .init())

        XCTAssertEqual(outcome.strategy, .rebase)
        XCTAssertEqual(outcome.baseLabel, "origin/main")
        XCTAssertEqual(outcome.baseSHA, movedSHA, "DiskGitClient.revParse should resolve origin/main to the just-pushed commit")
        XCTAssertEqual(outcome.appliedCommits, 1, "agent/alpha had one commit not yet on the moved base")
        XCTAssertTrue(outcome.fetched)
        XCTAssertEqual(outcome.fetchedRemote, "origin")
        XCTAssertFalse(outcome.fetchedFallback, "main was cloned from origin so its upstream is configured")

        // Topology check: agent/alpha is now a descendant of movedSHA.
        let runner = DiskProcessRunner()
        let mergeBase = try runner.run("/usr/bin/git",
                                       args: ["merge-base", "agent/alpha", movedSHA],
                                       cwd: taskPath, env: gitEnv).stdoutTrimmed
        XCTAssertEqual(mergeBase, movedSHA,
                       "agent/alpha must be ahead of moved origin/main after rebase")

        // lastSync persisted in state.
        let state = try TaskState.parse(try DiskFileSystem().readFile(at: workspace.statePath(for: task)))
        let sync = try XCTUnwrap(state.lastSync)
        XCTAssertEqual(sync.strategy, "rebase")
        XCTAssertEqual(sync.baseLabel, "origin/main")
        XCTAssertEqual(sync.baseSHA, movedSHA)
        XCTAssertEqual(sync.appliedCommits, 1)
    }

    // MARK: - no-op when remote hasn't moved

    func testNoOpWhenRemoteMainHasntMoved() throws {
        let workspace = try makeRemoteAndClone()
        let (task, taskPath) = try makeTask("beta", workspace: workspace)
        try commitInTaskWorktree(taskPath, filename: "b.swift",
                                 contents: "// beta\n",
                                 message: "feat: beta")

        let outcome = try makeSyncService(workspace).sync(task, options: .init())

        XCTAssertEqual(outcome.behindCount, 0, "main hasn't moved")
        XCTAssertEqual(outcome.appliedCommits, 0)
        XCTAssertTrue(outcome.fetched, "fetch still runs even on no-op")

        let state = try TaskState.parse(try DiskFileSystem().readFile(at: workspace.statePath(for: task)))
        XCTAssertEqual(state.lastSync?.appliedCommits, 0)
    }

    // MARK: - conflict surfaces as a typed error

    func testRebaseConflictBecomesSyncRebaseConflict() throws {
        let workspace = try makeRemoteAndClone()
        let (task, taskPath) = try makeTask("gamma", workspace: workspace)

        // Both sides edit README.md → guaranteed conflict on rebase.
        try commitInTaskWorktree(taskPath, filename: "README.md",
                                 contents: "task edit\n",
                                 message: "task edits README")
        _ = try advanceRemoteMain(filename: "README.md",
                                  contents: "remote edit\n",
                                  message: "remote edits README")

        XCTAssertThrowsError(try makeSyncService(workspace).sync(task, options: .init())) { error in
            guard case let VibeChardError.syncRebaseConflict(name, path, mode) = error else {
                return XCTFail("expected syncRebaseConflict, got \(error)")
            }
            XCTAssertEqual(name, "gamma")
            XCTAssertEqual(path, taskPath)
            XCTAssertEqual(mode, .rebase)
        }

        // No lastSync record on conflict.
        let state = try TaskState.parse(try DiskFileSystem().readFile(at: workspace.statePath(for: task)))
        XCTAssertNil(state.lastSync)

        // Leave git in a clean post-failure state for tearDown — abort
        // the in-progress rebase so the temp dir can be removed without
        // tripping over rebase-merge metadata.
        let runner = DiskProcessRunner()
        _ = try runner.run("/usr/bin/git",
                           args: ["rebase", "--abort"],
                           cwd: taskPath, env: gitEnv)
    }
}
