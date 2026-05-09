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
    /// `pid:command (samplePath)`. Bypass with `--allow-dirty`. (#10)
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
    /// `vch new --cd` and `--exec` were both passed. The two
    /// contracts are incompatible: `--cd` promises stdout = the
    /// worktree path; `--exec` execve's into the agent before vch
    /// would ever print. (#32B)
    case newConflictingCdExec
    /// `vch run` could not extract `PRODUCT_BUNDLE_IDENTIFIER` from
    /// `xcodebuild -showBuildSettings -json` for the resolved scheme
    /// — typically because the scheme has no app target. (#18)
    case runBundleIDNotFound(scheme: String)
    /// `vch run` could not find the just-built `.app` bundle on disk
    /// at the path xcodebuild reported. Usually means the build
    /// targeted a different destination than expected. (#18)
    case runAppBundleNotFound(path: String)
    /// `vch clean` refused because at least one process still holds
    /// a file inside the worktree's `.agent-build/` or `.vch/`
    /// (typically `xcodebuild` mid-flight). Re-run after the build
    /// finishes; `--dry-run` always succeeds. (#26)
    case cleanBlockedByHolders(task: String, holders: [WorktreeHolder])
    /// `vch sync` could not figure out which ref to rebase onto:
    /// nothing was passed via `--onto` and `state.json` has no
    /// recorded `baseBranch` (typically because `vch new` ran on a
    /// detached HEAD). Pass `--onto <ref>` explicitly. (#25)
    case syncBaseUnresolved(taskName: String)
    /// `vch sync` aborted because the task worktree has uncommitted
    /// changes. Pass `--allow-dirty` to let git decide whether the
    /// rebase / merge can still proceed. (#25)
    case syncDirtyWorktree(taskName: String, worktreePath: String)
    /// `git rebase` (or `git merge --no-ff`) hit a conflict while
    /// running `vch sync`. The git stderr was already streamed
    /// to the user; this wraps the failure to attach a hint that
    /// includes the task worktree path (since the user is *not*
    /// in that cwd — that's the whole point of vch). `mode` decides
    /// whether the hint mentions `git rebase --continue` or
    /// `git merge --continue`. (#25)
    case syncRebaseConflict(taskName: String, worktreePath: String, mode: SyncPlan.Strategy)
    /// `vch test --rerun` / `--rerun-failed` was invoked but the
    /// task has no recorded `lastTest` — i.e. the user never ran
    /// `vch test <name>` once. (#46)
    case testNoPriorRun(taskName: String)
    /// `vch test --rerun-failed` was invoked but the most recent run
    /// has no recorded failures (either the run was clean or the
    /// xcresult bundle is missing). (#46)
    case testNoPriorFailures(taskName: String)
    /// `vch test` saw both `--rerun` and `--rerun-failed`. They are
    /// mutually exclusive. (#46)
    case testConflictingRerunFlags
    /// `vch test` saw `--rerun` or `--rerun-failed` together with
    /// positional `extraArgs` (i.e. anything after `--`). The two
    /// contracts are incompatible: `--rerun*` reuses the recorded
    /// extra args verbatim, so passing fresh ones would be ignored
    /// or overridden. (#46)
    case testRerunWithExtraArgs
    /// `vch new --seed-spm-from <task>` was given a source task name
    /// that has no managed worktree. (#55)
    case seedSourceTaskNotFound(name: String)
    /// `vch new --seed-spm-from <task>` was given a source task that
    /// exists but has no SwiftPM bare-mirror cache yet — typically
    /// because the source task was never built. The user should run
    /// `vch build <source>` once before re-trying. (#55)
    case seedSourceHasNoSwiftPMCache(name: String, expectedPath: String)
    /// `vch sim warm-template create` was asked to create a template
    /// whose `vch-warm[<device>:<runtime>]` name is already taken in
    /// `simctl list devices`. The CLI never silently replaces — the
    /// user must `vch sim warm-template remove` first. (#47)
    case warmTemplateAlreadyExists(name: String, udid: String)
    /// User supplied a runtime label that didn't parse as any of
    /// the accepted forms (`iOS 26.4` / `iOS-26-4` / verbose
    /// CoreSimulator ID). (#47)
    case invalidRuntime(String)

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
            return "worktree has uncommitted changes: \(path) (use --allow-dirty to remove anyway)"
        case let .unmergedBranch(name):
            return "branch '\(name)' is not fully merged (use --allow-unmerged to delete)"
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
            return "worktree is held open by \(holders.count) process\(holders.count == 1 ? "" : "es") at \(path) — close the editor / shell or pass --allow-dirty:\n\(body)"
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
        case .newConflictingCdExec:
            return "--cd and --exec are mutually exclusive: --cd promises stdout = worktree path, --exec replaces vch with the command before any output"
        case let .runBundleIDNotFound(scheme):
            return "could not resolve PRODUCT_BUNDLE_IDENTIFIER for scheme '\(scheme)' — does this scheme build an app?"
        case let .runAppBundleNotFound(path):
            return "built app bundle not found at \(path) — was the build targeted at iOS Simulator?"
        case let .cleanBlockedByHolders(task, holders):
            let lines = holders.map { "  \($0.pid)\t\($0.command)\t(\($0.samplePath))" }
            let body = lines.joined(separator: "\n")
            return "refusing to clean '\(task)': \(holders.count) process\(holders.count == 1 ? "" : "es") still holding files inside .agent-build/ or .vch/ (xcodebuild mid-run?) — wait for it to finish or pass --dry-run:\n\(body)"
        case let .syncBaseUnresolved(taskName):
            return "refusing to sync: cannot determine base for task '\(taskName)' (no recorded baseBranch in state.json — vch new on detached HEAD?); pass --onto <ref> explicitly"
        case let .syncDirtyWorktree(taskName, worktreePath):
            return "refusing to sync: task '\(taskName)' has uncommitted changes at \(worktreePath). Either:\n  - cd \(worktreePath) && git stash\n  - or pass --allow-dirty (git will decide whether the rebase can proceed)"
        case let .syncRebaseConflict(taskName, worktreePath, mode):
            let verb: String
            let continueCmd: String
            let abortCmd: String
            switch mode {
            case .rebase:
                verb = "rebase"
                continueCmd = "git add -A && git rebase --continue"
                abortCmd = "git rebase --abort"
            case .merge:
                verb = "merge"
                continueCmd = "git add -A && git commit"
                abortCmd = "git merge --abort"
            }
            return "\(verb) paused on a conflict in 'agent/\(taskName)'.\n  resolve: cd \(worktreePath) && (edit files) && \(continueCmd)\n  abort:   cd \(worktreePath) && \(abortCmd)"
        case let .externalCommandFailed(cmd, code, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
            return "command failed (\(cmd), exit \(code))\(suffix)"
        case let .testNoPriorRun(taskName):
            return "refusing to rerun: task '\(taskName)' has no recorded test run yet — run `vch test \(taskName)` once first"
        case let .testNoPriorFailures(taskName):
            return "refusing --rerun-failed: task '\(taskName)' has no failed tests in the most recent run (run `vch test \(taskName) --rerun` to repeat the whole invocation)"
        case .testConflictingRerunFlags:
            return "--rerun and --rerun-failed are mutually exclusive"
        case .testRerunWithExtraArgs:
            return "--rerun / --rerun-failed cannot be combined with positional xcodebuild args after `--`: rerun reuses the recorded args verbatim"
        case let .seedSourceTaskNotFound(name):
            return "--seed-spm-from: source task '\(name)' not found (no managed worktree at <repo>-\(name)/)"
        case let .seedSourceHasNoSwiftPMCache(name, expectedPath):
            return "--seed-spm-from: source task '\(name)' has no SwiftPM cache yet at \(expectedPath) — run `vch build \(name)` once first"
        case let .warmTemplateAlreadyExists(name, udid):
            return "warm template '\(name)' already exists (\(udid.prefix(8))…) — run `vch sim warm-template remove` first if you want to recreate it"
        case let .invalidRuntime(label):
            return "could not parse runtime '\(label)' — accepted forms are '<platform> X.Y' (e.g. 'iOS 26.4', 'watchOS 11.5', 'visionOS 2.5'), '<platform>-X-Y' (e.g. 'iOS-26-4'), or the full SimRuntime identifier (e.g. 'com.apple.CoreSimulator.SimRuntime.iOS-26-4')"
        }
    }
}
