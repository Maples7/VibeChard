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
}
