import XCTest
@testable import VibeChardCore

final class TaskServiceTests: XCTestCase {

    private func makeService(
        repoPath: String = "/Users/me/Repo",
        clock: FixedClock = FixedClock()
    ) -> (TaskService, FakeGitClient, InMemoryFileSystem, FixedClock) {
        let workspace = Workspace(mainWorktreePath: repoPath)
        let git = FakeGitClient()
        let fs = InMemoryFileSystem()
        // Seed the main worktree so the porcelain list isn't empty.
        git.entries = [WorktreeEntry(path: repoPath, branch: "main")]
        fs.seedDirectory(repoPath)
        let service = TaskService(workspace: workspace, git: git, fs: fs, clock: clock)
        return (service, git, fs, clock)
    }

    // MARK: - new

    func testNewTaskCreatesWorktreeAndState() throws {
        let (service, git, fs, clock) = makeService()
        let task = try TaskName("foo")

        let path = try service.newTask(task)

        XCTAssertEqual(path, "/Users/me/Repo-foo")
        XCTAssertEqual(git.addNewBranchCalls.count, 1)
        XCTAssertEqual(git.addNewBranchCalls.first?.branch, "agent/foo")
        XCTAssertEqual(git.addNewBranchCalls.first?.base, "HEAD")

        let stateData = try fs.readFile(at: "/Users/me/Repo-foo/.vch/state.json")
        let state = try TaskState.parse(stateData)
        XCTAssertEqual(state.name, "foo")
        XCTAssertEqual(state.branch, "agent/foo")
        XCTAssertEqual(state.createdAt, clock.current)
        XCTAssertEqual(state.baseRef, "1234abc")
        XCTAssertEqual(state.schemaVersion, TaskState.currentSchemaVersion)
    }

    func testNewTaskRespectsCustomBaseRef() throws {
        let (service, git, _, _) = makeService()
        let task = try TaskName("foo")
        _ = try service.newTask(task, baseRef: "main")
        XCTAssertEqual(git.addNewBranchCalls.first?.base, "main")
    }

    func testNewTaskRefusesIfDirectoryExists() throws {
        let (service, _, fs, _) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo")
        XCTAssertThrowsError(try service.newTask(TaskName("foo"))) { error in
            guard case VibeChardError.worktreeAlreadyExists = error else {
                return XCTFail("expected worktreeAlreadyExists, got \(error)")
            }
        }
    }

    func testNewTaskRefusesIfBranchExists() throws {
        let (service, git, _, _) = makeService()
        git.branches.insert("agent/foo")
        XCTAssertThrowsError(try service.newTask(TaskName("foo"))) { error in
            guard case VibeChardError.worktreeAlreadyExists = error else {
                return XCTFail("expected worktreeAlreadyExists, got \(error)")
            }
        }
    }

    // MARK: - list

    func testListReturnsManagedWorktreesNewestFirst() throws {
        let (service, git, fs, _) = makeService()
        // Seed two managed worktrees with different createdAt.
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 9_000)
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-old", branch: "agent/old"))
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-new", branch: "agent/new"))
        // Plus an unrelated linked worktree we should ignore.
        git.entries.append(WorktreeEntry(path: "/Users/me/Other", branch: "release"))

        let oldState = TaskState(name: "old", branch: "agent/old", createdAt: oldDate, baseRef: "deadbeef")
        let newState = TaskState(name: "new", branch: "agent/new", createdAt: newDate, baseRef: "cafef00d")
        try fs.writeFileAtomic(oldState.jsonData(), to: "/Users/me/Repo-old/.vch/state.json")
        try fs.writeFileAtomic(newState.jsonData(), to: "/Users/me/Repo-new/.vch/state.json")

        let summaries = try service.listTasks()
        XCTAssertEqual(summaries.map(\.name), ["new", "old"])
        XCTAssertEqual(summaries.first?.path, "/Users/me/Repo-new")
        XCTAssertEqual(summaries.first?.baseRef, "cafef00d")
    }

    func testListSurvivesMissingStateFile() throws {
        let (service, git, _, _) = makeService()
        // Worktree dir-pattern matches but no state.json on disk.
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-orphan", branch: "agent/orphan"))
        let summaries = try service.listTasks()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.name, "orphan")
        XCTAssertNil(summaries.first?.createdAt)
    }

    // MARK: - path

    func testPathThrowsTaskNotFoundWhenMissing() throws {
        let (service, _, _, _) = makeService()
        XCTAssertThrowsError(try service.pathForTask(TaskName("ghost"))) { error in
            guard case VibeChardError.taskNotFound = error else {
                return XCTFail("expected taskNotFound, got \(error)")
            }
        }
    }

    func testPathReturnsAbsolutePathWhenExists() throws {
        let (service, _, fs, _) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo")
        let path = try service.pathForTask(TaskName("foo"))
        XCTAssertEqual(path, "/Users/me/Repo-foo")
    }

    // MARK: - remove

    func testRemoveRefusesDirtyWorktreeByDefault() throws {
        let (service, git, fs, _) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo")
        git.branches.insert("agent/foo")
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-foo", branch: "agent/foo"))
        git.dirtyWorktrees.insert("/Users/me/Repo-foo")

        XCTAssertThrowsError(try service.removeTask(TaskName("foo"))) { error in
            guard case VibeChardError.dirtyWorktree = error else {
                return XCTFail("expected dirtyWorktree, got \(error)")
            }
        }
        XCTAssertEqual(git.removeCalls.count, 0)
    }

    func testRemoveWithForceDirtyProceedsAndDeletesBranch() throws {
        let (service, git, fs, _) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo")
        git.branches.insert("agent/foo")
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-foo", branch: "agent/foo"))
        git.dirtyWorktrees.insert("/Users/me/Repo-foo")

        try service.removeTask(TaskName("foo"), options: .forceDirty)
        XCTAssertEqual(git.removeCalls.first?.path, "/Users/me/Repo-foo")
        XCTAssertEqual(git.removeCalls.first?.force, true)
        XCTAssertEqual(git.branchDeleteCalls, ["agent/foo"])
        XCTAssertEqual(git.branchDeleteForceCalls, [])
    }

    func testRemoveStopsAtUnmergedBranchWithoutDoubleForce() throws {
        let (service, git, fs, _) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo")
        git.branches.insert("agent/foo")
        git.unmergedBranches.insert("agent/foo")
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-foo", branch: "agent/foo"))

        XCTAssertThrowsError(try service.removeTask(TaskName("foo"))) { error in
            guard case VibeChardError.unmergedBranch = error else {
                return XCTFail("expected unmergedBranch, got \(error)")
            }
        }
        // Worktree should still be removed even though branch deletion failed.
        XCTAssertEqual(git.removeCalls.count, 1)
        XCTAssertEqual(git.branchDeleteForceCalls, [])
    }

    func testRemoveWithForceAllForceDeletesUnmergedBranch() throws {
        let (service, git, fs, _) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo")
        git.branches.insert("agent/foo")
        git.unmergedBranches.insert("agent/foo")
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-foo", branch: "agent/foo"))

        try service.removeTask(TaskName("foo"), options: .forceAll)
        XCTAssertEqual(git.branchDeleteForceCalls, ["agent/foo"])
        XCTAssertFalse(git.branches.contains("agent/foo"))
    }

    // MARK: - repair

    func testRepairPrunesAndCollectsProblems() throws {
        let (service, git, fs, _) = makeService()
        // good
        let good = TaskState(name: "good", branch: "agent/good", createdAt: Date(), baseRef: "abc")
        try fs.writeFileAtomic(good.jsonData(), to: "/Users/me/Repo-good/.vch/state.json")
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-good", branch: "agent/good"))
        // bad-no-state
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-orphan", branch: "agent/orphan"))
        // bad-corrupt
        fs.seedFile("/Users/me/Repo-junk/.vch/state.json", data: Data("{not json".utf8))
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-junk", branch: "agent/junk"))

        let report = try service.repair()
        XCTAssertEqual(git.pruneCalls, 1)
        XCTAssertTrue(report.prunedStaleEntries)
        XCTAssertEqual(Set(report.checkedTasks), Set(["good", "orphan", "junk"]))
        XCTAssertEqual(report.problems.count, 2)
        XCTAssertTrue(report.problems.contains(where: { $0.contains("orphan") && $0.contains("missing") }))
        XCTAssertTrue(report.problems.contains(where: { $0.contains("junk") }))
    }
}
