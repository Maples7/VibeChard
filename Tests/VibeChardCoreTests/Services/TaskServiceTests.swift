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

    func testNewTaskRefusesIfTaskAlreadyManagedAtArbitraryPath() throws {
        let (service, git, fs, _) = makeService()
        let adoptedPath = "/Users/me/agent-session"
        fs.seedDirectory(adoptedPath)
        git.entries.append(WorktreeEntry(path: adoptedPath, branch: "feature/foo"))
        let state = TaskState(
            name: "foo",
            branch: "feature/foo",
            createdAt: Date(),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        fs.seedFile(
            "\(adoptedPath)/.vch/state.json",
            data: try state.jsonData()
        )

        XCTAssertThrowsError(try service.newTask(TaskName("foo"))) { error in
            guard case let VibeChardError.worktreeAlreadyExists(path) = error else {
                return XCTFail("expected worktreeAlreadyExists, got \(error)")
            }
            XCTAssertEqual(path, adoptedPath)
        }
    }

    func testAdoptCurrentWorktreeWritesStateWithoutCreatingGitWorktree() throws {
        let (service, git, fs, clock) = makeService()
        let currentPath = "/Users/me/agent-session"
        fs.seedDirectory(currentPath)
        git.entries.append(WorktreeEntry(path: currentPath, branch: "feature/foo"))
        git.currentBranchByCwd["/Users/me/Repo"] = "main"
        git.currentBranchByCwd[currentPath] = "feature/foo"

        let path = try service.adoptCurrentWorktree(
            TaskName("foo"),
            currentWorktreePath: currentPath
        )

        XCTAssertEqual(path, currentPath)
        XCTAssertEqual(git.addNewBranchCalls.count, 0)
        XCTAssertEqual(git.appendExcludesCalls.first?.worktreeCwd, currentPath)

        let stateData = try fs.readFile(at: "\(currentPath)/.vch/state.json")
        let state = try TaskState.parse(stateData)
        XCTAssertEqual(state.name, "foo")
        XCTAssertEqual(state.branch, "feature/foo")
        XCTAssertEqual(state.createdAt, clock.current)
        XCTAssertEqual(state.baseRef, "1234abc")
        XCTAssertEqual(state.baseBranch, "main")
        XCTAssertEqual(state.worktreeOwnership, .adopted)
    }

    func testInferTaskNameForAdoptCurrentUsesLinkedWorktreeLeaf() throws {
        let (service, git, fs, _) = makeService()
        let currentPath = "/Users/me/agent-session"
        fs.seedDirectory(currentPath)
        git.entries.append(WorktreeEntry(path: currentPath, branch: "feature/foo"))

        let task = try service.inferTaskNameForAdoptCurrent(
            currentWorktreePath: currentPath
        )

        XCTAssertEqual(task.raw, "agent-session")
    }

    func testAdoptCurrentWorktreeRejectsMainWorktree() throws {
        let (service, _, _, _) = makeService()

        XCTAssertThrowsError(try service.adoptCurrentWorktree(
            TaskName("foo"),
            currentWorktreePath: "/Users/me/Repo"
        )) { error in
            guard case VibeChardError.adoptCurrentRequiresLinkedWorktree = error else {
                return XCTFail("expected adoptCurrentRequiresLinkedWorktree, got \(error)")
            }
        }
    }

    func testInferTaskNameForAdoptCurrentRejectsMainWorktree() throws {
        let (service, _, _, _) = makeService()

        XCTAssertThrowsError(try service.inferTaskNameForAdoptCurrent(
            currentWorktreePath: "/Users/me/Repo"
        )) { error in
            guard case VibeChardError.adoptCurrentRequiresLinkedWorktree = error else {
                return XCTFail("expected adoptCurrentRequiresLinkedWorktree, got \(error)")
            }
        }
    }

    func testAdoptCurrentWorktreeRejectsPathNotInGitWorktreeList() throws {
        let (service, _, fs, _) = makeService()
        fs.seedDirectory("/Users/me/random-dir")

        XCTAssertThrowsError(try service.adoptCurrentWorktree(
            TaskName("foo"),
            currentWorktreePath: "/Users/me/random-dir"
        )) { error in
            guard case VibeChardError.adoptCurrentRequiresLinkedWorktree = error else {
                return XCTFail("expected adoptCurrentRequiresLinkedWorktree, got \(error)")
            }
        }
        XCTAssertFalse(fs.fileExists(at: "/Users/me/random-dir/.vch/state.json"))
    }

    func testInferTaskNameForAdoptCurrentRejectsInvalidWorktreeLeaf() throws {
        let (service, git, fs, _) = makeService()
        let currentPath = "/Users/me/agent session"
        fs.seedDirectory(currentPath)
        git.entries.append(WorktreeEntry(path: currentPath, branch: "feature/foo"))

        XCTAssertThrowsError(try service.inferTaskNameForAdoptCurrent(
            currentWorktreePath: currentPath
        )) { error in
            guard case let VibeChardError.invalidTaskName(name, _) = error else {
                return XCTFail("expected invalidTaskName, got \(error)")
            }
            XCTAssertEqual(name, "agent session")
        }
    }

    func testAdoptCurrentWorktreeRefusesAlreadyManagedCurrentWorktree() throws {
        let (service, git, fs, _) = makeService()
        let currentPath = "/Users/me/agent-session"
        fs.seedDirectory(currentPath)
        git.entries.append(WorktreeEntry(path: currentPath, branch: "feature/old"))
        let state = TaskState(
            name: "old",
            branch: "feature/old",
            createdAt: Date(),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        fs.seedFile(
            "\(currentPath)/.vch/state.json",
            data: try state.jsonData()
        )

        XCTAssertThrowsError(try service.adoptCurrentWorktree(
            TaskName("foo"),
            currentWorktreePath: currentPath
        )) { error in
            guard case let VibeChardError.adoptCurrentAlreadyManaged(path, name) = error else {
                return XCTFail("expected adoptCurrentAlreadyManaged, got \(error)")
            }
            XCTAssertEqual(path, currentPath)
            XCTAssertEqual(name, "old")
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

    func testAdoptCurrentWorktreeCanCopyUntrackedFilesIntoCurrentWorktree() throws {
        let (service, git, fs, _) = makeService()
        let currentPath = "/Users/me/agent-session"
        fs.seedDirectory(currentPath)
        git.entries.append(WorktreeEntry(path: currentPath, branch: "feature/foo"))
        git.untrackedFilesByCwd["/Users/me/Repo"] = [".env"]
        fs.seedFile("/Users/me/Repo/.env", data: Data("LOCAL=1".utf8))

        _ = try service.adoptCurrentWorktree(
            TaskName("foo"),
            currentWorktreePath: currentPath,
            copyUntracked: true
        )

        XCTAssertEqual(git.listUntrackedCalls, ["/Users/me/Repo"])
        XCTAssertEqual(
            try fs.readFile(at: "\(currentPath)/.env"),
            Data("LOCAL=1".utf8)
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

    // MARK: - new --seed-spm-from (#55)

    func testSeedSpmFromClonesSourceRepositoriesIntoNewTask() throws {
        let (service, _, fs, _) = makeService()
        // Stand up a source task on disk with a populated SwiftPM
        // bare-mirror cache.
        fs.seedDirectory("/Users/me/Repo-source")
        fs.seedDirectory("/Users/me/Repo-source/.agent-build/SwiftPM/repositories")
        fs.seedFile(
            "/Users/me/Repo-source/.agent-build/SwiftPM/repositories/Foo.git/HEAD",
            data: Data("ref: refs/heads/main\n".utf8)
        )

        let path = try service.newTask(
            TaskName("follow-up"),
            seedSpmFrom: TaskName("source")
        )
        XCTAssertEqual(path, "/Users/me/Repo-follow-up")

        // The cloneItem call recorded the right (source, dest) pair.
        XCTAssertEqual(fs.cloneItemCalls.count, 1)
        XCTAssertEqual(
            fs.cloneItemCalls.first?.source,
            "/Users/me/Repo-source/.agent-build/SwiftPM/repositories"
        )
        XCTAssertEqual(
            fs.cloneItemCalls.first?.destination,
            "/Users/me/Repo-follow-up/.agent-build/SwiftPM/repositories"
        )

        // The destination repositories/ tree is materialized — file
        // contents reachable, mirrors the source's layout.
        XCTAssertEqual(
            try fs.readFile(at: "/Users/me/Repo-follow-up/.agent-build/SwiftPM/repositories/Foo.git/HEAD"),
            Data("ref: refs/heads/main\n".utf8)
        )

        // We must NOT have seeded checkouts/ or workspace-state.json
        // — those were proven non-portable in the spike.
        XCTAssertFalse(fs.directoryExists(at: "/Users/me/Repo-follow-up/.agent-build/SwiftPM/checkouts"))
        XCTAssertFalse(fs.fileExists(at: "/Users/me/Repo-follow-up/.agent-build/SwiftPM/workspace-state.json"))
    }

    func testSeedSpmFromThrowsWhenSourceTaskDoesNotExist() throws {
        let (service, _, _, _) = makeService()
        // No source worktree on disk.
        XCTAssertThrowsError(try service.newTask(
            TaskName("follow-up"),
            seedSpmFrom: TaskName("source")
        )) { error in
            guard case let VibeChardError.seedSourceTaskNotFound(name) = error else {
                return XCTFail("expected seedSourceTaskNotFound, got \(error)")
            }
            XCTAssertEqual(name, "source")
        }
    }

    func testSeedSpmFromThrowsWhenSourceHasNoSwiftPMCache() throws {
        let (service, _, fs, _) = makeService()
        // Source task exists but never ran a build — no
        // .agent-build/SwiftPM/repositories/.
        fs.seedDirectory("/Users/me/Repo-source")

        XCTAssertThrowsError(try service.newTask(
            TaskName("follow-up"),
            seedSpmFrom: TaskName("source")
        )) { error in
            guard case let VibeChardError.seedSourceHasNoSwiftPMCache(name, expected) = error else {
                return XCTFail("expected seedSourceHasNoSwiftPMCache, got \(error)")
            }
            XCTAssertEqual(name, "source")
            XCTAssertEqual(
                expected,
                "/Users/me/Repo-source/.agent-build/SwiftPM/repositories"
            )
        }
    }

    func testSeedSpmFromValidatesBeforeCreatingWorktree() throws {
        let (service, git, fs, _) = makeService()
        // Source task exists but has no SwiftPM cache — should
        // throw before any side effect on disk or git.
        fs.seedDirectory("/Users/me/Repo-source")

        XCTAssertThrowsError(try service.newTask(
            TaskName("follow-up"),
            seedSpmFrom: TaskName("source")
        ))

        XCTAssertEqual(git.addNewBranchCalls.count, 0,
            "no worktree should be created when seed validation fails")
        XCTAssertFalse(fs.directoryExists(at: "/Users/me/Repo-follow-up"),
            "no half-initialised worktree on disk")
    }

    func testNewTaskWithoutSeedSpmFromDoesNotCallCloneItem() throws {
        let (service, _, fs, _) = makeService()
        _ = try service.newTask(TaskName("foo"))
        XCTAssertEqual(fs.cloneItemCalls.count, 0,
            "cloneItem must only be invoked when --seed-spm-from is set")
    }

    func testSeedSpmFromExitCodeIsBusinessNotUsage() throws {
        // Both validation errors are business-state failures (the
        // user asked for a real action that can't proceed) — they
        // must not exit 2 (usage), which is reserved for argv-shape
        // errors that the user can fix without changing the world.
        XCTAssertEqual(
            VibeChardError.seedSourceTaskNotFound(name: "x").exitCode,
            ExitCode.business
        )
        XCTAssertEqual(
            VibeChardError.seedSourceHasNoSwiftPMCache(
                name: "x",
                expectedPath: "/p"
            ).exitCode,
            ExitCode.business
        )
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
        // Legacy vch-created worktree: dir-pattern and branch both
        // match, but state.json is missing on disk.
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-orphan", branch: "agent/orphan"))
        let summaries = try service.listTasks()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.name, "orphan")
        XCTAssertNil(summaries.first?.createdAt)
    }

    func testListSkipsCanonicalWorktreeWithoutStateOnExternalBranch() throws {
        let (service, git, _, _) = makeService()
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-external", branch: "feature/external"))

        let summaries = try service.listTasks()

        XCTAssertTrue(summaries.isEmpty)
    }

    func testListIncludesAdoptedWorktreeWithArbitraryPath() throws {
        let (service, git, fs, _) = makeService()
        let adoptedPath = "/Users/me/codex-session"
        git.entries.append(WorktreeEntry(path: adoptedPath, branch: "feature/adopted"))
        let state = TaskState(
            name: "adopted",
            branch: "feature/adopted",
            createdAt: Date(timeIntervalSince1970: 5_000),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        try fs.writeFileAtomic(state.jsonData(), to: "\(adoptedPath)/.vch/state.json")

        let summaries = try service.listTasks()

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.name, "adopted")
        XCTAssertEqual(summaries.first?.branch, "feature/adopted")
        XCTAssertEqual(summaries.first?.path, adoptedPath)
    }

    // MARK: - listTasks simulator column (#99)

    func testListShowsSingleSimulatorBindingByName() throws {
        let (service, git, fs, _) = makeService()
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-alpha", branch: "agent/alpha"))
        var state = TaskState(
            name: "alpha", branch: "agent/alpha",
            createdAt: Date(timeIntervalSince1970: 1_000),
            baseRef: "deadbeef"
        )
        state.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "U1", sourceUDID: "S1",
                name: "iPhone 16-vch-alpha"
            ),
        ])
        try fs.writeFileAtomic(state.jsonData(), to: "/Users/me/Repo-alpha/.vch/state.json")

        let summaries = try service.listTasks()
        XCTAssertEqual(summaries.first?.simulatorName, "iPhone 16-vch-alpha",
                       "1 binding renders as the bare name")
    }

    func testListShowsMultiBindingAggregatedFirstPlusCount() throws {
        let (service, git, fs, _) = makeService()
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-alpha", branch: "agent/alpha"))
        var state = TaskState(
            name: "alpha", branch: "agent/alpha",
            createdAt: Date(timeIntervalSince1970: 1_000),
            baseRef: "deadbeef"
        )
        state.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "U1", sourceUDID: "S1",
                name: "iPhone 16-vch-alpha"
            ),
            TaskState.SimulatorRecord(
                cloneUDID: "U2", sourceUDID: "S2",
                name: "Apple Watch Series 10-vch-alpha"
            ),
        ])
        try fs.writeFileAtomic(state.jsonData(), to: "/Users/me/Repo-alpha/.vch/state.json")

        let summaries = try service.listTasks()
        XCTAssertEqual(summaries.first?.simulatorName,
                       "iPhone 16-vch-alpha (+1)",
                       "2 bindings → first name + (+N) suffix")
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
        let (service, git, fs, _) = makeService()
        fs.seedDirectory("/Users/me/Repo-foo")
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-foo", branch: "agent/foo"))
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
        let (service, git, fs, _) = makeService()
        // Worktree dir exists but the user (or a half-finished checkout)
        // never wrote .vch/state.json.
        fs.seedDirectory("/Users/me/Repo-foo")
        git.entries.append(WorktreeEntry(path: "/Users/me/Repo-foo", branch: "agent/foo"))
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

    // MARK: - pathForTask / stateForTask through adopted-path override (#98 follow-up)

    /// `pathForTask` is the entry point most subcommands call to
    /// resolve "what's the cwd for this task". For an adopted task
    /// the `Workspace.taskWorktreePaths` override must win — otherwise
    /// every downstream subcommand silently operates on the wrong
    /// directory.
    func testPathForTaskHonoursAdoptedWorktreeOverride() throws {
        let adoptedPath = "/Users/me/codex-session"
        let task = try TaskName("codex-task")
        let workspace = Workspace(mainWorktreePath: "/Users/me/Repo")
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(adoptedPath)
        let state = TaskState(
            name: "codex-task",
            branch: "feature/codex",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        try fs.writeFileAtomic(state.jsonData(),
                               to: "\(adoptedPath)/.vch/state.json")
        let service = TaskService(workspace: workspace, git: FakeGitClient(),
                                  fs: fs, clock: FixedClock(Date()))

        let resolved = try service.pathForTask(task)
        XCTAssertEqual(resolved, adoptedPath)
    }

    /// `stateForTask` reads `state.json` from `workspace.statePath(for:)`,
    /// which must also follow the override. Symmetric guard for
    /// `pathForTask`.
    func testStateForTaskReadsFromAdoptedWorktree() throws {
        let adoptedPath = "/Users/me/codex-session"
        let task = try TaskName("codex-task")
        let workspace = Workspace(mainWorktreePath: "/Users/me/Repo")
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(adoptedPath)/.vch")
        let state = TaskState(
            name: "codex-task",
            branch: "feature/codex",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        try fs.writeFileAtomic(state.jsonData(),
                               to: "\(adoptedPath)/.vch/state.json")
        let service = TaskService(workspace: workspace, git: FakeGitClient(),
                                  fs: fs, clock: FixedClock(Date()))

        let read = try service.stateForTask(task)
        XCTAssertEqual(read.name, "codex-task")
        XCTAssertEqual(read.branch, "feature/codex")
        XCTAssertEqual(read.worktreeOwnership, .adopted)
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

    func testRemoveAdoptedTaskOnlyRemovesVchArtifacts() throws {
        let task = try TaskName("foo")
        let adoptedPath = "/Users/me/codex-session"
        let workspace = Workspace(mainWorktreePath: "/Users/me/Repo")
            .withWorktreePath(adoptedPath, for: task)
        let git = FakeGitClient()
        git.entries = [
            WorktreeEntry(path: "/Users/me/Repo", branch: "main"),
            WorktreeEntry(path: adoptedPath, branch: "feature/foo"),
        ]
        git.branches.insert("feature/foo")
        let fs = InMemoryFileSystem()
        fs.seedDirectory("/Users/me/Repo")
        fs.seedDirectory(adoptedPath)
        fs.seedFile("\(adoptedPath)/.agent-build/DerivedData/marker", data: Data("x".utf8))
        let state = TaskState(
            name: "foo",
            branch: "feature/foo",
            createdAt: Date(),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        fs.seedFile(
            "\(adoptedPath)/.vch/state.json",
            data: try state.jsonData()
        )
        let service = TaskService(workspace: workspace, git: git, fs: fs)

        try service.removeTask(task)

        XCTAssertTrue(fs.directoryExists(at: adoptedPath))
        XCTAssertFalse(fs.directoryExists(at: "\(adoptedPath)/.vch"))
        XCTAssertFalse(fs.directoryExists(at: "\(adoptedPath)/.agent-build"))
        XCTAssertTrue(git.removeCalls.isEmpty)
        XCTAssertTrue(git.branchDeleteCalls.isEmpty)
        XCTAssertTrue(git.branches.contains("feature/foo"))
    }

    func testRemoveAdoptedCanonicalPathUnregistersWithoutRediscovery() throws {
        let task = try TaskName("foo")
        let adoptedPath = "/Users/me/Repo-foo"
        let workspace = Workspace(mainWorktreePath: "/Users/me/Repo")
            .withWorktreePath(adoptedPath, for: task)
        let git = FakeGitClient()
        git.entries = [
            WorktreeEntry(path: "/Users/me/Repo", branch: "main"),
            WorktreeEntry(path: adoptedPath, branch: "feature/foo"),
        ]
        git.branches.insert("feature/foo")
        let fs = InMemoryFileSystem()
        fs.seedDirectory("/Users/me/Repo")
        fs.seedDirectory(adoptedPath)
        fs.seedFile("\(adoptedPath)/.agent-build/DerivedData/marker", data: Data("x".utf8))
        let state = TaskState(
            name: "foo",
            branch: "feature/foo",
            createdAt: Date(),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        fs.seedFile("\(adoptedPath)/.vch/state.json", data: try state.jsonData())
        let service = TaskService(workspace: workspace, git: git, fs: fs)

        try service.removeTask(task)

        XCTAssertTrue(fs.directoryExists(at: adoptedPath))
        XCTAssertFalse(fs.directoryExists(at: "\(adoptedPath)/.vch"))
        XCTAssertTrue(git.removeCalls.isEmpty)
        XCTAssertTrue(try service.listTasks().isEmpty)
        XCTAssertThrowsError(try service.removeTask(task, options: .forceAll)) { error in
            guard case VibeChardError.taskNotFound = error else {
                return XCTFail("expected taskNotFound, got \(error)")
            }
        }
        XCTAssertTrue(git.removeCalls.isEmpty)
        XCTAssertTrue(git.branches.contains("feature/foo"))
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

    func testRepairChecksAdoptedWorktreeWithArbitraryPath() throws {
        let (service, git, fs, _) = makeService()
        let adoptedPath = "/Users/me/codex-session"
        git.entries.append(WorktreeEntry(path: adoptedPath, branch: "feature/codex"))
        let state = TaskState(
            name: "codex-task",
            branch: "feature/codex",
            createdAt: Date(),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        try fs.writeFileAtomic(state.jsonData(), to: "\(adoptedPath)/.vch/state.json")

        let report = try service.repair()

        XCTAssertEqual(report.checkedTasks, ["codex-task"])
        XCTAssertTrue(report.problems.isEmpty)
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
        // ahead == 3 → not yet fully merged. (#67)
        XCTAssertEqual(status.mergedIntoBase, false)
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
        // Fall-back range is computed correctly, ahead > 0 → not
        // merged. (#67)
        XCTAssertEqual(status.mergedIntoBase, false)
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
        // No base → we cannot say whether the branch is merged. Stay
        // nil rather than guessing. (#67)
        XCTAssertNil(status.mergedIntoBase)
    }

    func testGitStatusReportsMergedIntoBaseWhenAheadIsZero() throws {
        let (service, _, _, _) = makeService()
        let summary = TaskSummary(
            name: "shipped",
            branch: "agent/shipped",
            path: "/Users/me/Repo-shipped",
            createdAt: nil,
            baseRef: "deadbee",
            baseBranch: "main",
            simulatorName: nil,
            lastBuildSucceeded: nil,
            lastBuildAt: nil
        )
        // No entry in revListCountByRange → fake returns 0. That's
        // exactly "branch is fully merged into base" — (#67) the
        // gate `vch prune` keys on.
        let status = service.gitStatus(forSummary: summary)
        XCTAssertEqual(status.aheadCount, 0)
        XCTAssertEqual(status.mergedIntoBase, true)
    }
}
