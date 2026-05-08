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

    // MARK: - new --copy-untracked

    func testNewTaskWithoutCopyUntrackedDoesNotListUntracked() throws {
        let (service, git, _, _) = makeService()
        _ = try service.newTask(TaskName("foo"))
        XCTAssertEqual(git.listUntrackedCalls, [],
            "untracked listing should be skipped when --copy-untracked is off")
    }

    func testNewTaskCopyUntrackedCopiesFilesPreservingLayout() throws {
        let (service, git, fs, _) = makeService(repoPath: "/Users/me/Repo")
        // Seed the source's untracked files.
        git.untrackedFilesByCwd["/Users/me/Repo"] = [
            ".env",
            ".vscode/settings.json",
            "scripts/local-only.sh",
        ]
        fs.seedFile("/Users/me/Repo/.env", data: Data("API_KEY=hunter2".utf8))
        fs.seedFile("/Users/me/Repo/.vscode/settings.json", data: Data("{}".utf8))
        fs.seedFile("/Users/me/Repo/scripts/local-only.sh", data: Data("#!/bin/sh\n".utf8))

        _ = try service.newTask(TaskName("foo"), copyUntracked: true)

        XCTAssertEqual(git.listUntrackedCalls, ["/Users/me/Repo"])
        // Each untracked file landed at the same relative path under
        // the new worktree.
        XCTAssertEqual(
            try fs.readFile(at: "/Users/me/Repo-foo/.env"),
            Data("API_KEY=hunter2".utf8)
        )
        XCTAssertEqual(
            try fs.readFile(at: "/Users/me/Repo-foo/.vscode/settings.json"),
            Data("{}".utf8)
        )
        XCTAssertEqual(
            try fs.readFile(at: "/Users/me/Repo-foo/scripts/local-only.sh"),
            Data("#!/bin/sh\n".utf8)
        )
    }

    func testNewTaskCopyUntrackedSkipsVchAndAgentBuild() throws {
        let (service, git, fs, _) = makeService()
        // Use names that aren't created by newTask itself — newTask
        // legitimately writes /Users/me/Repo-foo/.vch/state.json, so we
        // pick distinct paths so a "did we copy?" assertion isn't
        // confused by vch's own bookkeeping.
        git.untrackedFilesByCwd["/Users/me/Repo"] = [
            ".vch/leftover.json",
            ".vch/bin/xcodebuild",
            ".agent-build/cache/foo.o",
            ".env",
        ]
        fs.seedFile("/Users/me/Repo/.vch/leftover.json", data: Data("nope".utf8))
        fs.seedFile("/Users/me/Repo/.vch/bin/xcodebuild", data: Data("nope".utf8))
        fs.seedFile("/Users/me/Repo/.agent-build/cache/foo.o", data: Data("nope".utf8))
        fs.seedFile("/Users/me/Repo/.env", data: Data("ok".utf8))

        _ = try service.newTask(TaskName("foo"), copyUntracked: true)

        XCTAssertEqual(
            try fs.readFile(at: "/Users/me/Repo-foo/.env"),
            Data("ok".utf8)
        )
        XCTAssertFalse(fs.fileExists(at: "/Users/me/Repo-foo/.vch/leftover.json"),
            "stray .vch/* files in the source should never be copied across")
        XCTAssertFalse(fs.fileExists(at: "/Users/me/Repo-foo/.vch/bin/xcodebuild"),
            "vch's own scratch dir should never be copied across")
        XCTAssertFalse(fs.fileExists(at: "/Users/me/Repo-foo/.agent-build/cache/foo.o"),
            ".agent-build/ should never be copied across")
    }

    func testNewTaskCopyUntrackedRejectsPathEscapes() throws {
        let (service, git, fs, _) = makeService()
        git.untrackedFilesByCwd["/Users/me/Repo"] = [
            "/etc/passwd",          // absolute
            "../sibling-secret",    // path traversal
            "ok.txt",
        ]
        fs.seedFile("/Users/me/Repo/ok.txt", data: Data("ok".utf8))

        // Path-escape entries are silently dropped; the legitimate one
        // lands as expected. The state.json + worktree should still
        // exist, i.e. `vch new` doesn't fail on a hostile listing.
        _ = try service.newTask(TaskName("foo"), copyUntracked: true)
        XCTAssertEqual(
            try fs.readFile(at: "/Users/me/Repo-foo/ok.txt"),
            Data("ok".utf8)
        )
        XCTAssertFalse(fs.fileExists(at: "/Users/me/Repo-foo/../sibling-secret"))
    }

    func testNewTaskCopyUntrackedNoOpOnEmptyList() throws {
        let (service, git, _, _) = makeService()
        // No entry in `untrackedFilesByCwd` => fake returns [].
        let path = try service.newTask(TaskName("foo"), copyUntracked: true)
        XCTAssertEqual(path, "/Users/me/Repo-foo")
        XCTAssertEqual(git.listUntrackedCalls, ["/Users/me/Repo"])
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

    // MARK: - state

    func testStateThrowsTaskNotFoundWhenWorktreeMissing() throws {
        let (service, _, _, _) = makeService()
        XCTAssertThrowsError(try service.stateForTask(TaskName("ghost"))) { error in
            guard case VibeChardError.taskNotFound = error else {
                return XCTFail("expected taskNotFound, got \(error)")
            }
        }
    }

    func testStateThrowsStateFileMissingWhenWorktreeExistsButNoStateFile() throws {
        let (service, _, fs, _) = makeService()
        // Worktree dir exists but the user (or a half-finished checkout)
        // never wrote .vch/state.json.
        fs.seedDirectory("/Users/me/Repo-foo")
        XCTAssertThrowsError(try service.stateForTask(TaskName("foo"))) { error in
            guard case let VibeChardError.stateFileMissing(path) = error else {
                return XCTFail("expected stateFileMissing, got \(error)")
            }
            XCTAssertEqual(path, "/Users/me/Repo-foo/.vch/state.json")
        }
    }

    func testStateThrowsStateFileCorruptWithRealPathOnBadJSON() throws {
        let (service, _, fs, _) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo/.vch")
        try fs.writeFileAtomic(Data("not json".utf8),
                               to: "/Users/me/Repo-foo/.vch/state.json")
        XCTAssertThrowsError(try service.stateForTask(TaskName("foo"))) { error in
            guard case let VibeChardError.stateFileCorrupt(path, _) = error else {
                return XCTFail("expected stateFileCorrupt, got \(error)")
            }
            XCTAssertEqual(path, "/Users/me/Repo-foo/.vch/state.json",
                           "should re-throw with the real filesystem path, not '<in-memory>'")
        }
    }

    func testStateReturnsParsedStateForExistingTask() throws {
        let (service, _, fs, clock) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo/.vch")
        let state = TaskState(
            name: "foo",
            branch: "agent/foo",
            createdAt: clock.now(),
            baseRef: "abc1234"
        )
        try fs.writeFileAtomic(state.jsonData(),
                               to: "/Users/me/Repo-foo/.vch/state.json")
        let read = try service.stateForTask(TaskName("foo"))
        XCTAssertEqual(read.name, "foo")
        XCTAssertEqual(read.branch, "agent/foo")
        XCTAssertEqual(read.baseRef, "abc1234")
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

    // MARK: - listTasks baseBranch propagation (#24)

    func testListPopulatesBaseBranchFromState() throws {
        let (service, git, fs, _) = makeService()
        let state = TaskState(
            name: "feature",
            branch: "agent/feature",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbeef",
            baseBranch: "develop"
        )
        try fs.writeFileAtomic(state.jsonData(), to: "/Users/me/Repo-feature/.vch/state.json")
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-feature", branch: "agent/feature"))

        let summaries = try service.listTasks()
        XCTAssertEqual(summaries.first?.baseBranch, "develop")
        XCTAssertNil(summaries.first?.gitStatus,
                     "listTasks must not enrich; that's gitStatus(forSummary:)")
    }

    // MARK: - gitStatus(forSummary:) (#24)

    func testGitStatusReportsAheadBehindAndDirtyAndSubject() throws {
        let (service, git, _, _) = makeService()
        let summary = TaskSummary(
            name: "feature",
            branch: "agent/feature",
            path: "/Users/me/Repo-feature",
            createdAt: nil,
            baseRef: "deadbeef",
            baseBranch: "main",
            simulatorName: nil,
            lastBuildSucceeded: nil,
            lastBuildAt: nil
        )
        git.dirtyWorktrees.insert("/Users/me/Repo-feature")
        git.revListCountByRange["main..HEAD"] = 3
        git.revListCountByRange["HEAD..main"] = 1
        git.lastSubjectByBranch["HEAD"] = "wire up payment splitting"

        let status = service.gitStatus(forSummary: summary)
        XCTAssertEqual(status.aheadCount, 3)
        XCTAssertEqual(status.behindCount, 1)
        XCTAssertTrue(status.isDirty)
        XCTAssertEqual(status.lastCommitSubject, "wire up payment splitting")
    }

    func testGitStatusFallsBackToBaseRefWhenBaseBranchUnknown() throws {
        let (service, git, _, _) = makeService()
        let summary = TaskSummary(
            name: "feature",
            branch: "agent/feature",
            path: "/Users/me/Repo-feature",
            createdAt: nil,
            baseRef: "abc1234",
            baseBranch: nil,
            simulatorName: nil,
            lastBuildSucceeded: nil,
            lastBuildAt: nil
        )
        // Recorded against the SHA range so we can verify the fallback.
        git.revListCountByRange["abc1234..HEAD"] = 5
        git.revListCountByRange["HEAD..abc1234"] = 0

        let status = service.gitStatus(forSummary: summary)
        XCTAssertEqual(status.aheadCount, 5)
        XCTAssertEqual(status.behindCount, 0)
    }

    func testGitStatusLeavesAheadBehindNilWhenNoBaseAvailable() throws {
        let (service, _, _, _) = makeService()
        let summary = TaskSummary(
            name: "orphan",
            branch: "agent/orphan",
            path: "/Users/me/Repo-orphan",
            createdAt: nil,
            baseRef: nil,
            baseBranch: nil,
            simulatorName: nil,
            lastBuildSucceeded: nil,
            lastBuildAt: nil
        )
        let status = service.gitStatus(forSummary: summary)
        XCTAssertNil(status.aheadCount)
        XCTAssertNil(status.behindCount)
        // Dirty defaults to false (no entry in fake), subject nil.
        XCTAssertFalse(status.isDirty)
        XCTAssertNil(status.lastCommitSubject)
    }
}
