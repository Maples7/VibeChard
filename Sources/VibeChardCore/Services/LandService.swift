import Foundation

/// Orchestrates `vch land`: gathers a snapshot of git state, hands it
/// to `LandPlanner`, runs the merge if the planner approves, then
/// (unless `--keep`) removes the task worktree via `TaskService`. (#7)
public struct LandService: Sendable {
    public let workspace: Workspace
    public let git: GitClient
    public let fs: FileSystem
    public let clock: Clock
    public let simctl: SimctlClient

    public init(
        workspace: Workspace,
        git: GitClient,
        fs: FileSystem = DiskFileSystem(),
        clock: Clock = SystemClock(),
        simctl: SimctlClient = DiskSimctlClient()
    ) {
        self.workspace = workspace
        self.git = git
        self.fs = fs
        self.clock = clock
        self.simctl = simctl
    }

    public struct Options: Sendable {
        public var into: String?
        public var strategy: LandPlan.Strategy
        public var message: String?
        public var allowDirty: Bool
        public var dryRun: Bool
        /// `--keep` — skip the auto `vch rm` after a successful merge.
        public var keep: Bool
        /// `--keep-sim` — keep the per-task simulator clone even after
        /// a successful auto-`rm`. Symmetric with `vch rm --keep-sim`.
        /// Has no effect when `keep == true` (the task is still live,
        /// so its sim is never reaped). (#61)
        public var keepSim: Bool
        /// `--push` / `--push-to <remote>` — push the resolved
        /// `--into` branch to `<remote>` after the merge succeeds.
        /// `nil` = don't push (the default; never publish without
        /// being asked). (#49)
        public var push: Push?

        public init(
            into: String? = nil,
            strategy: LandPlan.Strategy = .noFF,
            message: String? = nil,
            allowDirty: Bool = false,
            dryRun: Bool = false,
            keep: Bool = false,
            keepSim: Bool = false,
            push: Push? = nil
        ) {
            self.into = into
            self.strategy = strategy
            self.message = message
            self.allowDirty = allowDirty
            self.dryRun = dryRun
            self.keep = keep
            self.keepSim = keepSim
            self.push = push
        }
    }

    /// Where `vch land --push` should push. `defaultRemote` resolves
    /// to the upstream tracked by the resolved `--into` branch
    /// (`branch.<into>.remote`), falling back to `"origin"` when
    /// the branch has no upstream configured. `explicit(name)` is the
    /// `--push-to <name>` form. (#49)
    public enum Push: Equatable, Sendable {
        case defaultRemote
        case explicit(String)
    }

    public struct Outcome: Equatable, Sendable {
        /// `false` only when `--dry-run` was passed.
        public let merged: Bool
        public let into: String
        public let strategy: LandPlan.Strategy
        public let message: String
        /// `true` when the task worktree was removed after a successful merge.
        public let removed: Bool
        /// Human-readable description if the auto-`rm` step failed but
        /// the merge already succeeded. The merge is not rolled back.
        public let removeError: String?
        /// `[base..task]` paths the merge touched, surfaced for `--dry-run`.
        public let touchedPaths: [String]
        /// `true` when the per-task simulator clone was deleted after
        /// a successful auto-`rm`. `false` when there was no clone
        /// recorded, when `--keep` / `--keep-sim` was passed, when
        /// auto-`rm` failed (worktree still on disk, so we leave the
        /// sim alone), or when `simctl.delete` itself failed. (#61)
        public let simRemoved: Bool
        /// Name of the simulator clone that was either deleted or
        /// that we tried (and failed) to delete. `nil` when the task
        /// had no recorded simulator. Surfaced even on failure so the
        /// CLI can show which device vch tried. (#61)
        public let simName: String?
        /// Human-readable description when the merge succeeded, the
        /// auto-`rm` succeeded, but `simctl delete` failed. The merge
        /// is not rolled back. (#61)
        public let simRemoveError: String?
        /// `true` when `--push` was requested and `git push` succeeded
        /// after the merge. `false` for every other case (push not
        /// requested, dry-run, push failed). (#49)
        public let pushed: Bool
        /// Resolved remote name used for `git push` when `--push` was
        /// requested. `nil` when no push was requested. Surfaced even
        /// on failure so the user sees which remote vch tried. (#49)
        public let pushRemote: String?
        /// Human-readable description when `--push` was requested but
        /// `git push` failed. The merge is not rolled back. (#49)
        public let pushError: String?

        public init(
            merged: Bool,
            into: String,
            strategy: LandPlan.Strategy,
            message: String,
            removed: Bool,
            removeError: String?,
            touchedPaths: [String],
            simRemoved: Bool = false,
            simName: String? = nil,
            simRemoveError: String? = nil,
            pushed: Bool = false,
            pushRemote: String? = nil,
            pushError: String? = nil
        ) {
            self.merged = merged
            self.into = into
            self.strategy = strategy
            self.message = message
            self.removed = removed
            self.removeError = removeError
            self.touchedPaths = touchedPaths
            self.simRemoved = simRemoved
            self.simName = simName
            self.simRemoveError = simRemoveError
            self.pushed = pushed
            self.pushRemote = pushRemote
            self.pushError = pushError
        }
    }

    @discardableResult
    public func land(_ task: TaskName, options: Options) throws -> Outcome {
        // Worktree + state must exist before we can do anything.
        let taskService = TaskService(workspace: workspace, git: git, fs: fs, clock: clock)
        let state = try taskService.stateForTask(task)
        let taskBranch = state.branch

        // Branch must still exist (state.json could be stale).
        guard try git.branchExists(repoCwd: workspace.mainWorktreePath, name: taskBranch) else {
            throw VibeChardError.landBranchMissing(branch: taskBranch)
        }

        // Snapshot main-worktree state.
        let currentMainBranch = try git.currentBranch(repoCwd: workspace.mainWorktreePath)

        // Pick a `--into` candidate to use for the diff/ahead-count
        // queries. The planner re-validates this choice.
        let intoForDiff = options.into ?? state.baseBranch ?? currentMainBranch
        guard let into = intoForDiff else {
            throw VibeChardError.landNoIntoInferred(taskName: task.raw)
        }

        let diff = try git.diffNamesOnly(
            repoCwd: workspace.mainWorktreePath,
            base: into,
            head: taskBranch
        )
        let aheadCount = try git.revListCount(
            repoCwd: workspace.mainWorktreePath,
            base: into,
            head: taskBranch
        )
        let dirtyPaths = try git.statusPaths(worktreeCwd: workspace.mainWorktreePath)
        let subject = try? git.lastNonMergeSubject(
            repoCwd: workspace.mainWorktreePath,
            branch: taskBranch
        )

        let inputs = LandPlan.Inputs(
            task: task,
            intoOption: options.into,
            recordedBaseBranch: state.baseBranch,
            currentMainBranch: currentMainBranch,
            strategy: options.strategy,
            userMessage: options.message,
            allowDirty: options.allowDirty,
            dryRun: options.dryRun,
            removeAfter: !options.keep,
            dirtyPathsOnMain: dirtyPaths,
            taskDiffPaths: diff,
            taskAheadCount: aheadCount,
            taskHeadSubject: subject
        )

        let decision = LandPlanner.plan(inputs)
        switch decision {
        case .abort(let reason):
            throw makeError(reason: reason, taskName: task.raw)
        case .proceed(let resolved):
            if resolved.dryRun {
                return Outcome(
                    merged: false,
                    into: resolved.into,
                    strategy: resolved.strategy,
                    message: resolved.message,
                    removed: false,
                    removeError: nil,
                    touchedPaths: diff,
                    simRemoved: false,
                    simName: state.simulator?.name,
                    simRemoveError: nil
                )
            }
            // Run the merge. Bubble up `externalCommandFailed` —
            // the user wants to see git's exact stderr (likely a
            // conflict marker) and we won't auto-rm a half-merged
            // state.
            try git.merge(
                repoCwd: workspace.mainWorktreePath,
                branch: taskBranch,
                mode: gitMode(for: resolved.strategy),
                message: resolved.message
            )

            // Auto rm. Failure here is non-fatal — the merge already
            // landed, and the user can run `vch rm <name>` manually
            // after fixing whatever blocked us.
            var removed = false
            var removeError: String?
            if resolved.removeAfter {
                do {
                    try taskService.removeTask(task, options: .init())
                    removed = true
                } catch {
                    removeError = String(describing: error)
                }
            }

            // Per-task simulator clone cleanup. Symmetric with
            // `vch rm`: if auto-`rm` succeeded and the user did not
            // pass `--keep-sim`, delete the sim clone bound to the
            // task. Skipped when:
            //   * `--keep` / `--keep-sim` was passed,
            //   * auto-`rm` failed (worktree still on disk — the
            //     user may retry; reaping the sim now would leave
            //     them with a half-broken task),
            //   * the task never recorded a simulator (no `vch build sim`).
            // Failure of `simctl.delete` is non-fatal and surfaces
            // via `simRemoveError`; the merge is never rolled back.
            // (#61)
            var simRemoved = false
            var simRemoveError: String?
            let simRecord = state.simulator
            if removed, !options.keepSim, let sim = simRecord {
                do {
                    try simctl.delete(udid: sim.cloneUDID)
                    simRemoved = true
                } catch {
                    simRemoveError = String(describing: error)
                }
            }

            // Optional `git push`. The merge already succeeded; we
            // never roll it back if push fails. Attempt is recorded
            // in the Outcome so the CLI can surface the failure as
            // a warning the user sees right after the merge line. (#49)
            var pushed = false
            var pushRemote: String?
            var pushError: String?
            if let pushSpec = options.push {
                let remote: String
                switch pushSpec {
                case .defaultRemote:
                    let upstream = (try? git.upstreamRemote(
                        repoCwd: workspace.mainWorktreePath,
                        branch: resolved.into
                    )) ?? nil
                    remote = upstream ?? "origin"
                case .explicit(let name):
                    remote = name
                }
                pushRemote = remote
                do {
                    try git.push(
                        repoCwd: workspace.mainWorktreePath,
                        remote: remote,
                        branch: resolved.into
                    )
                    pushed = true
                } catch {
                    pushError = String(describing: error)
                }
            }

            return Outcome(
                merged: true,
                into: resolved.into,
                strategy: resolved.strategy,
                message: resolved.message,
                removed: removed,
                removeError: removeError,
                touchedPaths: diff,
                simRemoved: simRemoved,
                simName: simRecord?.name,
                simRemoveError: simRemoveError,
                pushed: pushed,
                pushRemote: pushRemote,
                pushError: pushError
            )
        }
    }

    private func makeError(reason: LandPlan.Decision.Reason, taskName: String) -> VibeChardError {
        switch reason {
        case let .mainNotOnInto(currentBranch, want):
            return .landMainNotOnInto(currentBranch: currentBranch, want: want)
        case let .mergeOverlap(paths):
            return .landMergeOverlap(paths: paths)
        case let .noOp(taskBranch, into):
            return .landNoOp(taskBranch: taskBranch, into: into)
        case .noIntoInferred:
            return .landNoIntoInferred(taskName: taskName)
        }
    }

    private func gitMode(for strategy: LandPlan.Strategy) -> GitMergeMode {
        switch strategy {
        case .noFF:   return .noFF
        case .ffOnly: return .ffOnly
        case .squash: return .squash
        }
    }
}
