import XCTest
@testable import VibeChardCore

final class TaskRemovalIntegrationTests: XCTestCase {
    private var root: URL!
    private var workspace: Workspace!
    private let task = try! TaskName("cleanup")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vch-remove-it-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("Repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        workspace = Workspace(mainWorktreePath: repo)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "vch test"])
        try git(["config", "user.email", "vch@test.local"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try git(["commit", "--allow-empty", "-qm", "initial"])
        try git(["branch", "develop"])
        try git(["commit", "--allow-empty", "-qm", "release"])
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func git(_ args: [String], cwd: String? = nil) throws -> String {
        let result = try DiskProcessRunner().run(
            "/usr/bin/git", args: args, cwd: cwd ?? workspace.mainWorktreePath
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "git \(args.joined(separator: " "))",
                exitCode: result.exitCode, stderr: result.stderr
            )
        }
        return result.stdoutTrimmed
    }

    private func service(git client: GitClient = DiskGitClient()) -> TaskService {
        TaskService(workspace: workspace, git: client)
    }

    func testRefusalOnDifferentMainWorktreeBranchPreservesStateAndBothClones() throws {
        let service = service()
        let path = try service.newTask(task)
        var state = try service.stateForTask(task)
        state.setSimulators([
            .init(cloneUDID: "IOS", sourceUDID: "SOURCE-IOS", name: "iPhone-vch-cleanup"),
            .init(cloneUDID: "WATCH", sourceUDID: "SOURCE-WATCH", name: "Watch-vch-cleanup"),
        ])
        let stateData = try state.jsonData()
        try DiskFileSystem().writeFileAtomic(stateData, to: workspace.statePath(for: task))
        let simctl = FakeSimctl()
        simctl.devices = state.allSimulators.map {
            SimDevice(udid: $0.cloneUDID, name: $0.name, runtime: "iOS-26-4",
                      runtimeVersion: nil, isAvailable: true, state: "Shutdown")
        }
        try git(["switch", "develop"])

        XCTAssertThrowsError(try service.removeTask(task, simctl: simctl)) { error in
            guard case VibeChardError.unmergedBranch = error else {
                return XCTFail("expected unmergedBranch, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: workspace.statePath(for: task))), stateData)
        XCTAssertEqual(try git(["branch", "--show-current"], cwd: path), task.branchName)
        XCTAssertEqual(try service.listTasks().map(\.name), [task.raw])
        XCTAssertTrue(simctl.deleteCalls.isEmpty)

        try service.removeTask(task, options: .init(allowUnmergedBranch: true), simctl: simctl)
        XCTAssertEqual(simctl.deleteCalls, ["IOS", "WATCH"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(try DiskGitClient().branchExists(repoCwd: workspace.mainWorktreePath, name: task.branchName))
        XCTAssertTrue(try service.listTasks().isEmpty)
    }

    func testResolvableUpstreamTakesPrecedenceOverUnmergedHEAD() throws {
        let service = service()
        let path = try service.newTask(task)
        try git(["branch", "--set-upstream-to=main", task.branchName])
        try git(["switch", "develop"])

        try service.removeTask(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testUnmergedUpstreamRefusesEvenWhenMergedIntoHEAD() throws {
        let service = service()
        let path = try service.newTask(task)
        try git(["branch", "--set-upstream-to=develop", task.branchName])

        XCTAssertThrowsError(try service.removeTask(task)) { error in
            guard case VibeChardError.unmergedBranch = error else {
                return XCTFail("expected unmergedBranch, got \(error)")
            }
        }
        XCTAssertEqual(try git(["branch", "--show-current"], cwd: path), task.branchName)
        XCTAssertNoThrow(try service.stateForTask(task))
    }

    func testNewDetachedCommitAfterPartialRemovalRequiresAllowUnmerged() throws {
        let service = service()
        let path = try service.newTask(task)
        let failingService = self.service(git: DiskGitClient(runner: RemovalFailingRunner()))
        XCTAssertThrowsError(try failingService.removeTask(task))
        try git(["commit", "--allow-empty", "-qm", "new detached work"], cwd: path)

        XCTAssertThrowsError(try service.removeTask(task)) { error in
            guard case VibeChardError.unmergedBranch = error else {
                return XCTFail("expected unmergedBranch, got \(error)")
            }
        }
        XCTAssertNoThrow(try service.stateForTask(task))
        try service.removeTask(task, options: .init(allowUnmergedBranch: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testDetachedCommitBeforeRemovalIsProtectedEvenWhenTaskBranchIsMerged() throws {
        let service = service()
        let path = try service.newTask(task)
        try git(["switch", "--detach"], cwd: path)
        try git(["commit", "--allow-empty", "-qm", "detached work"], cwd: path)

        XCTAssertThrowsError(try service.removeTask(task))
        XCTAssertTrue(try DiskGitClient().branchExists(repoCwd: workspace.mainWorktreePath, name: task.branchName))
        XCTAssertNoThrow(try service.stateForTask(task))
    }

    func testUpstreamMergedPartialRemovalCanRetryWithSameFlags() throws {
        let service = service()
        let path = try service.newTask(task)
        try git(["branch", "--set-upstream-to=main", task.branchName])
        try git(["switch", "develop"])
        let failingService = self.service(git: DiskGitClient(runner: RemovalFailingRunner()))
        XCTAssertThrowsError(try failingService.removeTask(task))

        try service.removeTask(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testMissingUpstreamFallsBackToHEAD() throws {
        let service = service()
        let path = try service.newTask(task)
        try git(["branch", "temporary-upstream"])
        try git(["branch", "--set-upstream-to=temporary-upstream", task.branchName])
        try git(["branch", "-D", "temporary-upstream"])

        try service.removeTask(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFailedWorktreeRemovalRetainsDetachedCommitDirtyFilesAndStateForRetry() throws {
        let service = service()
        let path = try service.newTask(task)
        let commit = try git(["rev-parse", "HEAD"], cwd: path)
        let dirtyFile = "\(path)/work-in-progress.txt"
        try "keep until removal succeeds".write(toFile: dirtyFile, atomically: true, encoding: .utf8)
        let failingService = self.service(git: DiskGitClient(runner: RemovalFailingRunner()))

        XCTAssertThrowsError(try failingService.removeTask(task, options: .forceAll))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], cwd: path), commit)
        XCTAssertEqual(try git(["branch", "--show-current"], cwd: path), "")
        XCTAssertEqual(try String(contentsOfFile: dirtyFile), "keep until removal succeeds")
        XCTAssertNoThrow(try service.stateForTask(task))
        XCTAssertEqual(try service.listTasks().map(\.name), [task.raw])

        XCTAssertThrowsError(try service.removeTask(task))
        try service.removeTask(task, options: .forceAll)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testLockedWorktreeRefusesBeforeBranchDeletion() throws {
        let service = service()
        let path = try service.newTask(task)
        try git(["worktree", "lock", "--reason", "test", path])

        XCTAssertThrowsError(try service.removeTask(task, options: .forceAll))
        XCTAssertEqual(try git(["branch", "--show-current"], cwd: path), task.branchName)
        XCTAssertNoThrow(try service.stateForTask(task))

        try git(["worktree", "unlock", path])
        try service.removeTask(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

private struct RemovalFailingRunner: ProcessRunner {
    func run(_ executable: String, args: [String], cwd: String?, env: [String: String]?) throws -> ProcessResult {
        if args.starts(with: ["worktree", "remove"]) {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "injected removal failure")
        }
        return try DiskProcessRunner().run(executable, args: args, cwd: cwd, env: env)
    }
}
