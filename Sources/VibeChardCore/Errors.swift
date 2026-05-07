import Foundation

/// All errors VibeChard surfaces to the CLI. Each variant carries enough
/// context to render a human-readable message *and* to map to a stable
/// `ExitCode`. Throwing a `VibeChardError` is the only allowed way to
/// terminate a Core operation.
public enum VibeChardError: Error, CustomStringConvertible {
    // Usage / validation (exit 2)
    case invalidTaskName(String, reason: String)
    case missingArgument(String)

    // Business state (exit 1)
    case worktreeAlreadyExists(path: String)
    case taskNotFound(name: String)
    case worktreeNotAGitRepository(path: String)
    case dirtyWorktree(path: String)
    case unmergedBranch(name: String)
    case stateFileCorrupt(path: String, underlying: String)
    case stateSchemaMismatch(found: Int, expected: Int)
    case stateFileMissing(path: String)
    case simulatorTemplateNotFound(name: String)
    case simulatorAlreadyBound(taskName: String, currentName: String, requestedName: String)
    /// `vch remove` refused because at least one process still holds
    /// a file inside the worktree. Each `WorktreeHolder` is rendered
    /// `pid:command (samplePath)`. Bypass with `--force`. (#10)
    case worktreeBusy(path: String, holders: [WorktreeHolder])
    /// `vch logs` could not find the requested log file. Used when a
    /// user runs `vch logs <name>` before the task has executed any
    /// build / test through vch yet. (#9)
    case logFileMissing(path: String, hint: String)
    /// `vch land` aborted because the main worktree's HEAD is not on
    /// the requested `--into` branch. (#7)
    case landMainNotOnInto(currentBranch: String?, want: String)
    /// `vch land` aborted because the main worktree has uncommitted
    /// changes whose paths intersect the task branch's diff. Pass
    /// `--allow-dirty` to override. (#7)
    case landMergeOverlap(paths: [String])
    /// `vch land` aborted because the task branch is not strictly
    /// ahead of the merge target — the merge would be a no-op. (#7)
    case landNoOp(taskBranch: String, into: String)
    /// `vch land` could not figure out which branch to merge into:
    /// nothing was recorded in `state.json` and the main worktree is
    /// in a detached HEAD. Pass `--into <branch>` explicitly. (#7)
    case landNoIntoInferred(taskName: String)
    /// `vch land` could not find the task's branch — it was deleted
    /// outside vch, or `state.json` is stale. (#7)
    case landBranchMissing(branch: String)
    /// `vch land` was invoked with more than one strategy flag among
    /// `--no-ff`, `--ff-only`, `--squash`. (#7)
    case landConflictingStrategies
    /// `vch run` could not extract `PRODUCT_BUNDLE_IDENTIFIER` from
    /// `xcodebuild -showBuildSettings -json` for the resolved scheme
    /// — typically because the scheme has no app target. (#18)
    case runBundleIDNotFound(scheme: String)
    /// `vch run` could not find the just-built `.app` bundle on disk
    /// at the path xcodebuild reported. Usually means the build
    /// targeted a different destination than expected. (#18)
    case runAppBundleNotFound(path: String)

    // External command failure (exit 3)
    case externalCommandFailed(cmd: String, exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case let .invalidTaskName(name, reason):
            return "invalid task name '\(name)': \(reason)"
        case let .missingArgument(name):
            return "missing argument: \(name)"
        case let .worktreeAlreadyExists(path):
            return "worktree already exists at \(path)"
        case let .taskNotFound(name):
            return "task not found: '\(name)'"
        case let .worktreeNotAGitRepository(path):
            return "not a git repository: \(path)"
        case let .dirtyWorktree(path):
            return "worktree has uncommitted changes: \(path) (use --force to remove anyway)"
        case let .unmergedBranch(name):
            return "branch '\(name)' is not fully merged (use --force --force to delete)"
        case let .stateFileCorrupt(path, underlying):
            return "state file corrupt at \(path): \(underlying) (run `vch repair`)"
        case let .stateSchemaMismatch(found, expected):
            return "state schema v\(found) does not match this vch (expected v\(expected)); run `vch repair`"
        case let .stateFileMissing(path):
            return "state file missing at \(path) (run `vch repair`)"
        case let .simulatorTemplateNotFound(name):
            return "no available simulator template named '\(name)' (try `xcrun simctl list devices available`)"
        case let .simulatorAlreadyBound(task, current, requested):
            return "task '\(task)' is already bound to simulator '\(current)' — refusing to clone '\(requested)' (use `vch sim erase` or remove the task first)"
        case let .worktreeBusy(path, holders):
            let lines = holders.map { "  \($0.pid)\t\($0.command)\t(\($0.samplePath))" }
            let body = lines.joined(separator: "\n")
            return "worktree is held open by \(holders.count) process\(holders.count == 1 ? "" : "es") at \(path) — close the editor / shell or pass --force:\n\(body)"
        case let .logFileMissing(path, hint):
            return "no log file at \(path) — \(hint)"
        case let .landMainNotOnInto(currentBranch, want):
            let cur = currentBranch.map { "'\($0)'" } ?? "(detached HEAD)"
            return "refusing to land: main worktree is on \(cur), not '\(want)' (use `git switch \(want)` first or pass --into)"
        case let .landMergeOverlap(paths):
            let listing = paths.map { "  \($0)" }.joined(separator: "\n")
            return "refusing to land: \(paths.count) file\(paths.count == 1 ? "" : "s") in main worktree overlap the task branch's diff (stash or commit them, or pass --allow-dirty):\n\(listing)"
        case let .landNoOp(taskBranch, into):
            return "refusing to land: '\(taskBranch)' has no commits ahead of '\(into)' (nothing to merge)"
        case let .landNoIntoInferred(taskName):
            return "refusing to land: cannot infer --into for task '\(taskName)' (no recorded base branch and main worktree has detached HEAD); pass --into <branch>"
        case let .landBranchMissing(branch):
            return "refusing to land: branch '\(branch)' does not exist (was it deleted outside vch?)"
        case .landConflictingStrategies:
            return "--no-ff, --ff-only, --squash are mutually exclusive"
        case let .runBundleIDNotFound(scheme):
            return "could not resolve PRODUCT_BUNDLE_IDENTIFIER for scheme '\(scheme)' — does this scheme build an app?"
        case let .runAppBundleNotFound(path):
            return "built app bundle not found at \(path) — was the build targeted at iOS Simulator?"
        case let .externalCommandFailed(cmd, code, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
            return "command failed (\(cmd), exit \(code))\(suffix)"
        }
    }
}
