import Foundation

/// Orchestrates `vch land`: gathers a snapshot of git state, hands it
/// to `LandPlanner`, runs the merge if the planner approves, then
/// (unless `--keep`) removes the task worktree via `TaskService`. (#7)
public struct LandService: Sendable {
    public let workspace: Workspace
    public let git: GitClient
    public let fs: FileSystem
    public let clock: Clock

    public init(
        workspace: Workspace,
        git: GitClient,
        fs: FileSystem = DiskFileSystem(),
        clock: Clock = SystemClock()
    ) {
        self.workspace = workspace
        self.git = git
        self.fs = fs
        self.clock = clock
    }

    public struct Options: Sendable {
        public var into: String?
        public var strategy: LandPlan.Strategy
        public var message: String?
        public var allowDirty: Bool
        public var dryRun: Bool
        /// `--keep` — skip the auto `vch rm` after a successful merge.
        public var keep: Bool

        public init(
            into: String? = nil,
            strategy: LandPlan.Strategy = .noFF,
            message: String? = nil,
            allowDirty: Bool = false,
            dryRun: Bool = false,
            keep: Bool = false
        ) {
            self.into = into
            self.strategy = strategy
            self.message = message
            self.allowDirty = allowDirty
            self.dryRun = dryRun
            self.keep = keep
        }
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

        public init(
            merged: Bool,
            into: String,
            strategy: LandPlan.Strategy,
            message: String,
            removed: Bool,
            removeError: String?,
            touchedPaths: [String]
        ) {
            self.merged = merged
            self.into = into
            self.strategy = strategy
            self.message = message
            self.removed = removed
            self.removeError = removeError
            self.touchedPaths = touchedPaths
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
                    touchedPaths: diff
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

            return Outcome(
                merged: true,
                into: resolved.into,
                strategy: resolved.strategy,
                message: resolved.message,
                removed: removed,
                removeError: removeError,
                touchedPaths: diff
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
