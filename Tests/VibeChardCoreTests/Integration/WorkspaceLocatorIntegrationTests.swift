import XCTest
@testable import VibeChardCore

/// End-to-end tests for `WorkspaceLocator` against a real `/usr/bin/git`
/// in a unique temp directory. Exercises both `locate(cwd:)` (the
/// pre-existing API) and `resolveCurrent(cwd:)` (added for `vch open`'s
/// cwd inference).
///
/// Skipped automatically if git is not on disk (e.g. minimal CI).
final class WorkspaceLocatorIntegrationTests: XCTestCase {

    private var rootDir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                      "/usr/bin/git not available")
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vch-locator-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDir, FileManager.default.fileExists(atPath: rootDir.path) {
            try? FileManager.default.removeItem(at: rootDir)
        }
    }

    // MARK: - Helpers

    /// Initialize a fresh repo at `<rootDir>/Repo` with one commit. The
    /// returned `Workspace` is the canonical main-worktree handle.
    private func makeRepo() throws -> Workspace {
        // Canonicalize via git itself, because macOS's `/var` is a
        // symlink to `/private/var` and `URL.resolvingSymlinksInPath`
        // doesn't normalize that special prefix. `WorkspaceLocator`
        // returns whatever git's `rev-parse --show-toplevel` says, so
        // the test fixture must speak the same dialect.
        let rawRepoPath = rootDir.appendingPathComponent("Repo").path
        try FileManager.default.createDirectory(atPath: rawRepoPath, withIntermediateDirectories: true)
        let runner = DiskProcessRunner()
        let env = gitEnv()
        try requireSuccess(runner.run("/usr/bin/git", args: ["init", "-q", "-b", "main"], cwd: rawRepoPath, env: env))
        try requireSuccess(runner.run("/usr/bin/git", args: ["config", "commit.gpgsign", "false"], cwd: rawRepoPath, env: env))
        let topResult = try runner.run("/usr/bin/git", args: ["rev-parse", "--show-toplevel"], cwd: rawRepoPath, env: env)
        try requireSuccess(topResult)
        let repoPath = topResult.stdoutTrimmed
        try "hello".write(toFile: "\(repoPath)/README.md", atomically: true, encoding: .utf8)
        try requireSuccess(runner.run("/usr/bin/git", args: ["add", "README.md"], cwd: repoPath, env: env))
        try requireSuccess(runner.run("/usr/bin/git", args: ["commit", "-q", "-m", "initial"], cwd: repoPath, env: env))
        return Workspace(mainWorktreePath: repoPath)
    }

    /// Create a vch-style linked worktree at `<parent>/<repo>-<task>`
    /// on a fresh `agent/<task>` branch. Doesn't go through `TaskService`
    /// so these tests stay decoupled from anything but git.
    private func addLinkedWorktree(workspace: Workspace, taskRaw: String) throws -> String {
        let path = workspace.parentDirectory + "/\(workspace.repoName)-\(taskRaw)"
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run(
            "/usr/bin/git",
            args: ["worktree", "add", "-b", "agent/\(taskRaw)", path],
            cwd: workspace.mainWorktreePath,
            env: gitEnv()
        ))
        return path
    }

    private func gitEnv() -> [String: String] {
        [
            "GIT_AUTHOR_NAME": "vch test",
            "GIT_AUTHOR_EMAIL": "vch@test.local",
            "GIT_COMMITTER_NAME": "vch test",
            "GIT_COMMITTER_EMAIL": "vch@test.local",
            "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": rootDir.path,
            "XDG_CONFIG_HOME": rootDir.appendingPathComponent("xdg").path,
        ]
    }

    private func requireSuccess(_ result: ProcessResult, file: StaticString = #filePath, line: UInt = #line) throws {
        if !result.succeeded {
            XCTFail("command failed: \(result.stderr)", file: file, line: line)
            throw VibeChardError.externalCommandFailed(cmd: "git", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    // MARK: - locate(cwd:)

    func testLocateFromMainWorktreeRoot() throws {
        let workspace = try makeRepo()
        let resolved = try WorkspaceLocator.locate(cwd: workspace.mainWorktreePath)
        XCTAssertEqual(resolved.mainWorktreePath, workspace.mainWorktreePath)
        XCTAssertEqual(resolved.repoName, "Repo")
    }

    func testLocateFromSubdirectoryWalksUpToMainWorktree() throws {
        let workspace = try makeRepo()
        let sub = "\(workspace.mainWorktreePath)/Sources/Deep"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)

        let resolved = try WorkspaceLocator.locate(cwd: sub)
        XCTAssertEqual(resolved.mainWorktreePath, workspace.mainWorktreePath)
    }

    func testLocateFromLinkedWorktreeStillReturnsMain() throws {
        let workspace = try makeRepo()
        _ = try addLinkedWorktree(workspace: workspace, taskRaw: "alpha")
        let linkedPath = workspace.parentDirectory + "/Repo-alpha"

        let resolved = try WorkspaceLocator.locate(cwd: linkedPath)
        // Whether we stand in the main or a linked worktree, locate
        // must hand back the main — that's the workspace identity.
        XCTAssertEqual(resolved.mainWorktreePath, workspace.mainWorktreePath)
    }

    func testLocateRejectsNonGitDirectory() throws {
        let plainDir = rootDir.appendingPathComponent("not-a-repo").path
        try FileManager.default.createDirectory(atPath: plainDir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try WorkspaceLocator.locate(cwd: plainDir)) { error in
            guard case VibeChardError.worktreeNotAGitRepository = error else {
                return XCTFail("expected worktreeNotAGitRepository, got \(error)")
            }
        }
    }

    // MARK: - resolveCurrent(cwd:)

    func testResolveCurrentInMainWorktreeReturnsNilTaskName() throws {
        let workspace = try makeRepo()
        let resolved = try WorkspaceLocator.resolveCurrent(cwd: workspace.mainWorktreePath)
        XCTAssertEqual(resolved.workspace.mainWorktreePath, workspace.mainWorktreePath)
        XCTAssertNil(resolved.taskName,
                     "main worktree cwd should yield nil taskName so callers can prompt for one")
    }

    func testResolveCurrentInLinkedWorktreeRootInfersTaskName() throws {
        let workspace = try makeRepo()
        _ = try addLinkedWorktree(workspace: workspace, taskRaw: "alpha")
        let linkedPath = workspace.parentDirectory + "/Repo-alpha"

        let resolved = try WorkspaceLocator.resolveCurrent(cwd: linkedPath)
        XCTAssertEqual(resolved.workspace.mainWorktreePath, workspace.mainWorktreePath)
        XCTAssertEqual(resolved.taskName?.raw, "alpha")
    }

    func testResolveCurrentInLinkedWorktreeSubdirInfersTaskName() throws {
        let workspace = try makeRepo()
        _ = try addLinkedWorktree(workspace: workspace, taskRaw: "alpha")
        let sub = workspace.parentDirectory + "/Repo-alpha/Sources/Deep"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)

        let resolved = try WorkspaceLocator.resolveCurrent(cwd: sub)
        XCTAssertEqual(resolved.workspace.mainWorktreePath, workspace.mainWorktreePath)
        XCTAssertEqual(resolved.taskName?.raw, "alpha",
                       "git rev-parse --show-toplevel walks up to the worktree root regardless of cwd depth")
    }

    func testResolveCurrentInWronglyNamedSiblingWorktreeReturnsNilTaskName() throws {
        // Hand-create a worktree whose leaf doesn't follow `<repo>-<task>`.
        // vch should treat it as "not a vch worktree" — same workspace,
        // but no inferred task name.
        let workspace = try makeRepo()
        let oddPath = workspace.parentDirectory + "/sidecar"
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run(
            "/usr/bin/git",
            args: ["worktree", "add", "-b", "feature/sidecar", oddPath],
            cwd: workspace.mainWorktreePath,
            env: gitEnv()
        ))

        let resolved = try WorkspaceLocator.resolveCurrent(cwd: oddPath)
        XCTAssertEqual(resolved.workspace.mainWorktreePath, workspace.mainWorktreePath)
        XCTAssertNil(resolved.taskName,
                     "leaf 'sidecar' doesn't match 'Repo-<task>' so resolution must fall back to nil")
    }

    func testLocateIndexesAdoptedWorktreeStateAtArbitraryPath() throws {
        let workspace = try makeRepo()
        let adoptedPath = workspace.parentDirectory + "/codex-session"
        let runner = DiskProcessRunner()
        try requireSuccess(runner.run(
            "/usr/bin/git",
            args: ["worktree", "add", "-b", "feature/codex", adoptedPath],
            cwd: workspace.mainWorktreePath,
            env: gitEnv()
        ))
        let state = TaskState(
            name: "codex-task",
            branch: "feature/codex",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        try FileManager.default.createDirectory(
            atPath: "\(adoptedPath)/.vch",
            withIntermediateDirectories: true
        )
        try state.jsonData().write(to: URL(fileURLWithPath: "\(adoptedPath)/.vch/state.json"))

        let located = try WorkspaceLocator.locate(cwd: workspace.mainWorktreePath)
        XCTAssertEqual(
            located.worktreePath(for: try TaskName("codex-task")),
            adoptedPath
        )

        let resolved = try WorkspaceLocator.resolveCurrent(cwd: adoptedPath)
        XCTAssertEqual(resolved.taskName?.raw, "codex-task")
        XCTAssertEqual(
            resolved.workspace.worktreePath(for: try TaskName("codex-task")),
            adoptedPath
        )
    }

    func testResolveCurrentRejectsNonGitDirectory() throws {
        let plainDir = rootDir.appendingPathComponent("not-a-repo").path
        try FileManager.default.createDirectory(atPath: plainDir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try WorkspaceLocator.resolveCurrent(cwd: plainDir)) { error in
            guard case VibeChardError.worktreeNotAGitRepository = error else {
                return XCTFail("expected worktreeNotAGitRepository, got \(error)")
            }
        }
    }
}
