import Foundation

/// CLI-side helper that resolves the main worktree path for a given
/// directory. Uses `git rev-parse --show-toplevel` then resolves linked
/// worktrees back to the main one via `git worktree list --porcelain`.
public enum WorkspaceLocator {
    /// Find the workspace whose main worktree contains, or is a sibling
    /// of, `cwd`. The user can be standing either in the main worktree
    /// or in any linked (vch-managed) worktree — we always resolve back
    /// to the main one.
    public static func locate(cwd: String, runner: ProcessRunner = DiskProcessRunner()) throws -> Workspace {
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
        return Workspace(mainWorktreePath: main.path)
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
        runner: ProcessRunner = DiskProcessRunner()
    ) throws -> (workspace: Workspace, taskName: TaskName?) {
        let workspace = try locate(cwd: cwd, runner: runner)

        // Re-ask git for the cwd's own toplevel — `locate` already
        // walked it but didn't expose it. The cost is one extra git
        // exec; cheap relative to the IDE launch we're about to do.
        let topResult = try runner.run(
            "/usr/bin/git",
            args: ["rev-parse", "--show-toplevel"],
            cwd: cwd
        )
        guard topResult.succeeded else { return (workspace, nil) }
        let toplevel = topResult.stdoutTrimmed
        if toplevel.isEmpty || toplevel == workspace.mainWorktreePath {
            return (workspace, nil)
        }
        guard let raw = workspace.taskNameRaw(forWorktreePath: toplevel) else {
            return (workspace, nil)
        }
        // The leaf naming matches but the suffix may not be a valid
        // TaskName (e.g. someone hand-created a sibling like
        // `BeanLedger-foo bar`). Treat that as "not a vch worktree".
        if let task = try? TaskName(raw) {
            return (workspace, task)
        }
        return (workspace, nil)
    }
}
