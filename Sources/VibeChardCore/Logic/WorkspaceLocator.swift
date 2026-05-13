import Foundation

public struct WorkspaceLocation: Equatable, Sendable {
    public let workspace: Workspace
    public let currentWorktreePath: String
    public let taskName: TaskName?

    public var isMainWorktree: Bool {
        currentWorktreePath == workspace.mainWorktreePath
    }

    public init(workspace: Workspace, currentWorktreePath: String, taskName: TaskName?) {
        self.workspace = workspace
        self.currentWorktreePath = currentWorktreePath
        self.taskName = taskName
    }
}

/// CLI-side helper that resolves the main worktree path for a given
/// directory. Uses `git rev-parse --show-toplevel` then resolves linked
/// worktrees back to the main one via `git worktree list --porcelain`.
public enum WorkspaceLocator {
    /// Find the workspace whose main worktree contains, or is a sibling
    /// of, `cwd`. The user can be standing either in the main worktree
    /// or in any linked (vch-managed) worktree — we always resolve back
    /// to the main one.
    public static func locate(
        cwd: String,
        runner: ProcessRunner = DiskProcessRunner(),
        fs: FileSystem = DiskFileSystem()
    ) throws -> Workspace {
        try locateCurrent(cwd: cwd, runner: runner, fs: fs).workspace
    }

    public static func locateCurrent(
        cwd: String,
        runner: ProcessRunner = DiskProcessRunner(),
        fs: FileSystem = DiskFileSystem()
    ) throws -> WorkspaceLocation {
        // Step 1: ask git for the toplevel of whichever worktree we're in.
        let topResult = try runner.run("/usr/bin/git", args: ["rev-parse", "--show-toplevel"], cwd: cwd)
        guard topResult.succeeded else {
            throw VibeChardError.worktreeNotAGitRepository(path: cwd)
        }
        let toplevel = topResult.stdoutTrimmed
        if toplevel.isEmpty {
            throw VibeChardError.worktreeNotAGitRepository(path: cwd)
        }

        // Step 2: get the porcelain list. The first entry is always the
        // main worktree (per `git worktree list` semantics).
        let listResult = try runner.run("/usr/bin/git", args: ["worktree", "list", "--porcelain"], cwd: toplevel)
        guard listResult.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "git worktree list --porcelain",
                exitCode: listResult.exitCode,
                stderr: listResult.stderr
            )
        }
        let entries = PorcelainParser.parseWorktreeList(listResult.stdout)
        guard let main = entries.first else {
            throw VibeChardError.worktreeNotAGitRepository(path: cwd)
        }
        let workspace = workspace(mainPath: main.path, entries: entries, fs: fs)
        let taskName = taskNameForCurrentWorktree(
            toplevel: toplevel,
            workspace: workspace,
            fs: fs
        )
        return WorkspaceLocation(
            workspace: workspace,
            currentWorktreePath: Workspace(mainWorktreePath: toplevel).mainWorktreePath,
            taskName: taskName
        )
    }

    /// Resolve both the workspace AND, if `cwd` is inside a vch-managed
    /// linked worktree, the corresponding `TaskName`. Used by commands
    /// that want to default the task arg to "the worktree I'm standing
    /// in" — e.g. `vch open` with no name.
    ///
    /// Returns `taskName == nil` when `cwd` is in the main worktree
    /// (i.e. not a vch-managed task), or when the linked worktree's
    /// directory name doesn't follow the `<repo>-<task>` convention.
    public static func resolveCurrent(
        cwd: String,
        runner: ProcessRunner = DiskProcessRunner(),
        fs: FileSystem = DiskFileSystem()
    ) throws -> (workspace: Workspace, taskName: TaskName?) {
        let location = try locateCurrent(cwd: cwd, runner: runner, fs: fs)
        return (location.workspace, location.taskName)
    }

    private static func workspace(
        mainPath: String,
        entries: [WorktreeEntry],
        fs: FileSystem
    ) -> Workspace {
        let normalizedMain = Workspace(mainWorktreePath: mainPath).mainWorktreePath
        var taskPaths: [String: String] = [:]
        for entry in entries where Workspace(mainWorktreePath: entry.path).mainWorktreePath != normalizedMain {
            let statePath = PathOps.join(entry.path, Workspace.stateJsonRelativePath)
            guard fs.fileExists(at: statePath),
                  let data = try? fs.readFile(at: statePath),
                  let state = try? TaskState.parse(data),
                  (try? TaskName(state.name)) != nil else {
                continue
            }
            taskPaths[state.name] = entry.path
        }
        return Workspace(mainWorktreePath: normalizedMain, taskWorktreePaths: taskPaths)
    }

    private static func taskNameForCurrentWorktree(
        toplevel: String,
        workspace: Workspace,
        fs: FileSystem
    ) -> TaskName? {
        let normalizedTop = Workspace(mainWorktreePath: toplevel).mainWorktreePath
        if normalizedTop == workspace.mainWorktreePath {
            return nil
        }

        let statePath = PathOps.join(normalizedTop, Workspace.stateJsonRelativePath)
        if fs.fileExists(at: statePath),
           let data = try? fs.readFile(at: statePath),
           let state = try? TaskState.parse(data),
           let task = try? TaskName(state.name) {
            return task
        }

        // The leaf naming matches but the suffix may not be a valid
        // TaskName (e.g. someone hand-created a sibling like
        // `BeanLedger-foo bar`). Treat that as "not a vch worktree".
        if let raw = workspace.taskNameRaw(forWorktreePath: normalizedTop),
           let task = try? TaskName(raw) {
            return task
        }
        return nil
    }
}
