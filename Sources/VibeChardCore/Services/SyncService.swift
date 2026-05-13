import Foundation

/// Orchestrates `vch sync <name>`: gathers task state, optionally
/// fetches the upstream remote, resolves the base ref, asks
/// `SyncPlanner` whether the task branch is already up to date, and
/// runs `git rebase` (or `git merge --no-ff`) inside the task
/// worktree on success. (#25)
///
/// Why rebase by default
/// ---------------------
/// `agent/<name>` branches are local-only by vch's contract. They're
/// not pushed, not shared, not someone else's history — so rewriting
/// them to keep a linear history is safe and produces a cleaner
/// `vch land --squash` (or `--ff-only`) later. `--merge` exists for
/// users who manually pushed `agent/<name>` somewhere a coworker now
/// reads from; auto-detection of that case is intentionally out of
/// scope for v0.4.x.
///
/// Why fetch only `state.baseBranch`'s upstream
/// --------------------------------------------
/// We *could* parse `--onto origin/foo` and fetch its remote — but
/// `--onto` is an escape hatch and the user can pre-fetch themselves
/// (or pass `--no-fetch`). Restricting fetch to `state.baseBranch`
/// keeps the fetch deterministic and avoids surprising network calls
/// when the user types a non-remote ref like `HEAD~3`.
public struct SyncService: Sendable {
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
        /// Override `state.baseBranch`. Accepts any ref `git rev-parse`
        /// can resolve.
        public var onto: String?
        public var strategy: SyncPlan.Strategy
        public var allowDirty: Bool
        public var noFetch: Bool
        public var dryRun: Bool

        public init(
            onto: String? = nil,
            strategy: SyncPlan.Strategy = .rebase,
            allowDirty: Bool = false,
            noFetch: Bool = false,
            dryRun: Bool = false
        ) {
            self.onto = onto
            self.strategy = strategy
            self.allowDirty = allowDirty
            self.noFetch = noFetch
            self.dryRun = dryRun
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let strategy: SyncPlan.Strategy
        public let baseLabel: String
        public let baseSHA: String
        public let aheadCount: Int
        public let behindCount: Int
        public let appliedCommits: Int
        public let dryRun: Bool
        public let fetched: Bool
        /// The remote `git fetch` actually used, if any. `nil` when
        /// `--no-fetch` was passed or when the remote couldn't be
        /// inferred (and the fallback also failed). `"origin"` is
        /// recorded when `state.baseBranch` had no upstream remote
        /// configured and we fell back.
        public let fetchedRemote: String?
        /// `true` when `state.baseBranch` had no upstream remote and
        /// we fell back to `origin`. Lets the CLI emit a one-line
        /// stderr warning the user can act on.
        public let fetchedFallback: Bool
        public let durationSeconds: Double
    }

    /// Diagnostic events the CLI surface uses to render progress
    /// without the service caring whether it's stderr text, JSON, or
    /// suppressed by `--quiet`. (#25)
    public enum Event: Sendable {
        case fetching(remote: String, branch: String)
        case fetchSkipped(reason: SkipReason)
        case fallbackToOrigin(baseBranch: String)
        case rebasing(taskBranch: String, onto: String)
        case merging(taskBranch: String, onto: String)
        case alreadyUpToDate(taskBranch: String, onto: String)
        case dryRunPlan(strategy: SyncPlan.Strategy, baseLabel: String,
                        ahead: Int, behind: Int)

        public enum SkipReason: Sendable {
            case userOptOut       // --no-fetch
            case noBaseBranch     // state has neither baseBranch nor --onto with remote prefix
        }
    }

    @discardableResult
    public func sync(
        _ task: TaskName,
        options: Options,
        progress: ((Event) -> Void)? = nil
    ) throws -> Outcome {
        let started = clock.now()
        let taskService = TaskService(workspace: workspace, git: git, fs: fs, clock: clock)
        let state = try taskService.stateForTask(task)
        let worktreePath = workspace.worktreePath(for: task)

        // 1. Resolve base label. Throw early — no IO yet. The label
        //    is `var` because step 3 may *promote* an implicit
        //    state.baseBranch (e.g. "main") to its remote-tracking
        //    form ("origin/main") after a successful fetch — local
        //    branches don't move when you `git fetch`, so we have to
        //    rebase onto the remote-tracking ref to actually pick up
        //    the new commits. (#25)
        guard var baseLabel = options.onto ?? state.baseBranch, !baseLabel.isEmpty else {
            throw VibeChardError.syncBaseUnresolved(taskName: task.raw)
        }

        // 2. Cheap dirty check (local) before any fetch. The
        //    `--allow-dirty` flag is a pass-through: vch skips the
        //    pre-check and lets git refuse if the rebase actually
        //    can't proceed.
        if !options.allowDirty {
            let dirty = try git.statusIsDirty(worktreeCwd: worktreePath)
            if dirty {
                throw VibeChardError.syncDirtyWorktree(
                    taskName: task.raw,
                    worktreePath: worktreePath
                )
            }
        }

        // 3. Fetch (unless --no-fetch). Fetch logic looks at
        //    `state.baseBranch` only — `--onto` is *not* used to
        //    decide what to fetch. If state has no recorded
        //    baseBranch (detached-HEAD origin), skip fetch entirely.
        var fetched = false
        var fetchedRemote: String?
        var fetchedFallback = false
        if options.noFetch {
            progress?(.fetchSkipped(reason: .userOptOut))
        } else if let recorded = state.baseBranch, !recorded.isEmpty {
            // Strip `<remote>/` prefix when `recorded` is itself a
            // remote-tracking ref (e.g. `origin/main`) — `git fetch`
            // wants the upstream branch name, not the local
            // remote-tracking ref.
            let (preferredRemote, branchOnRemote) = splitRemotePrefix(recorded)

            let resolvedRemote: String
            if let preferred = preferredRemote {
                resolvedRemote = preferred
            } else if let configured = try git.upstreamRemote(
                repoCwd: worktreePath,
                branch: branchOnRemote
            ) {
                resolvedRemote = configured
            } else {
                resolvedRemote = "origin"
                fetchedFallback = true
                progress?(.fallbackToOrigin(baseBranch: recorded))
            }

            progress?(.fetching(remote: resolvedRemote, branch: branchOnRemote))
            try git.fetch(
                repoCwd: worktreePath,
                remote: resolvedRemote,
                branch: branchOnRemote
            )
            fetched = true
            fetchedRemote = resolvedRemote

            // Promote `baseLabel` to the freshly-fetched remote-
            // tracking ref. `TaskService.newTask` records
            // `state.baseBranch` as the *local* branch name (e.g.
            // "main"), but `git fetch origin main` only updates
            // `refs/remotes/origin/main`; the local `main` ref does
            // not move. So if we left `baseLabel = "main"`, the
            // subsequent rev-parse + rebase would target the stale
            // pre-fetch SHA. The promotion fixes that.
            //
            // Skipped when the user passed `--onto` (escape hatch:
            // they chose the rebase target explicitly), and a no-op
            // when `state.baseBranch` was already a remote-tracking
            // ref like "origin/main" (the resulting label is
            // identical).
            if options.onto == nil {
                baseLabel = "\(resolvedRemote)/\(branchOnRemote)"
            }
        } else {
            progress?(.fetchSkipped(reason: .noBaseBranch))
        }

        // 4. Resolve baseLabel → baseSHA.
        let baseSHA = try git.revParse(repoCwd: worktreePath, ref: baseLabel)

        // 5. Compute ahead/behind. ahead = task commits not yet on
        //    base; behind = base commits the task hasn't absorbed.
        let taskBranch = state.branch
        let aheadCount = try git.revListCount(
            repoCwd: worktreePath,
            base: baseSHA,
            head: taskBranch
        )
        let behindCount = try git.revListCount(
            repoCwd: worktreePath,
            base: taskBranch,
            head: baseSHA
        )

        // 6. Hand off to the planner.
        let inputs = SyncPlan.Inputs(
            strategy: options.strategy,
            baseLabel: baseLabel,
            baseSHA: baseSHA,
            aheadCount: aheadCount,
            behindCount: behindCount,
            dryRun: options.dryRun
        )
        let decision = SyncPlanner.plan(inputs)

        switch decision {
        case .noop(let resolved):
            progress?(.alreadyUpToDate(
                taskBranch: taskBranch,
                onto: resolved.baseLabel
            ))
            // Still write lastSync (with appliedCommits=0) on real
            // runs; dry-run leaves state untouched.
            let finished = clock.now()
            if !options.dryRun {
                try writeLastSync(
                    task: task,
                    finishedAt: finished,
                    resolved: resolved,
                    appliedCommits: 0,
                    durationSeconds: duration(from: started, to: finished)
                )
            }
            return Outcome(
                strategy: resolved.strategy,
                baseLabel: resolved.baseLabel,
                baseSHA: resolved.baseSHA,
                aheadCount: resolved.aheadCount,
                behindCount: 0,
                appliedCommits: 0,
                dryRun: resolved.dryRun,
                fetched: fetched,
                fetchedRemote: fetchedRemote,
                fetchedFallback: fetchedFallback,
                durationSeconds: duration(from: started, to: finished)
            )

        case .proceed(let resolved):
            if resolved.dryRun {
                progress?(.dryRunPlan(
                    strategy: resolved.strategy,
                    baseLabel: resolved.baseLabel,
                    ahead: resolved.aheadCount,
                    behind: resolved.behindCount
                ))
                let finished = clock.now()
                return Outcome(
                    strategy: resolved.strategy,
                    baseLabel: resolved.baseLabel,
                    baseSHA: resolved.baseSHA,
                    aheadCount: resolved.aheadCount,
                    behindCount: resolved.behindCount,
                    appliedCommits: 0,
                    dryRun: true,
                    fetched: fetched,
                    fetchedRemote: fetchedRemote,
                    fetchedFallback: fetchedFallback,
                    durationSeconds: duration(from: started, to: finished)
                )
            }

            // Run rebase or merge. On externalCommandFailed, wrap as
            // syncRebaseConflict so the CLI prints a hint with the
            // worktree path. Other git failures (e.g. unknown ref)
            // bubble through as-is.
            do {
                switch resolved.strategy {
                case .rebase:
                    progress?(.rebasing(
                        taskBranch: taskBranch,
                        onto: resolved.baseLabel
                    ))
                    try git.rebase(worktreeCwd: worktreePath, onto: resolved.baseLabel)
                case .merge:
                    progress?(.merging(
                        taskBranch: taskBranch,
                        onto: resolved.baseLabel
                    ))
                    // #98 follow-up: for `--adopt-current` tasks the
                    // real branch lives in `state.branch` (here
                    // `taskBranch`). Constructing the message from
                    // `task.raw` produced "Merge X into agent/codex-task"
                    // for an adopted task whose branch was actually
                    // `feature/codex` — same shape of bug as the
                    // LandPlanner regression fixed in this PR.
                    let message = "Merge \(resolved.baseLabel) into \(taskBranch)"
                    try git.merge(
                        repoCwd: worktreePath,
                        branch: resolved.baseLabel,
                        mode: .noFF,
                        message: message
                    )
                }
            } catch let VibeChardError.externalCommandFailed(cmd, _, _)
                where cmd.hasPrefix("git rebase") || cmd.hasPrefix("git merge") {
                throw VibeChardError.syncRebaseConflict(
                    taskName: task.raw,
                    worktreePath: worktreePath,
                    mode: resolved.strategy
                )
            }

            // Success. Compute appliedCommits = pre-rebase ahead. The
            // rebase replays exactly the task commits onto base, so
            // aheadCount captured before the rebase is the right
            // number. (For `--merge`, applied counts the merge-commit
            // itself; we still report `aheadCount` for parity since
            // it's the count the user cares about.)
            let appliedCommits = resolved.aheadCount
            let finished = clock.now()
            try writeLastSync(
                task: task,
                finishedAt: finished,
                resolved: resolved,
                appliedCommits: appliedCommits,
                durationSeconds: duration(from: started, to: finished)
            )

            return Outcome(
                strategy: resolved.strategy,
                baseLabel: resolved.baseLabel,
                baseSHA: resolved.baseSHA,
                aheadCount: resolved.aheadCount,
                behindCount: resolved.behindCount,
                appliedCommits: appliedCommits,
                dryRun: false,
                fetched: fetched,
                fetchedRemote: fetchedRemote,
                fetchedFallback: fetchedFallback,
                durationSeconds: duration(from: started, to: finished)
            )
        }
    }

    // MARK: - Helpers

    /// If `ref` looks like `<remote>/<branch>` *and* `<remote>` is a
    /// non-empty leading segment, return `(remote, branch)`. Otherwise
    /// `(nil, ref)`. We don't validate against `git remote` here —
    /// the planner doesn't do IO. The fallback / `upstreamRemote`
    /// path will catch a typo'd remote when the actual `git fetch`
    /// fails.
    private func splitRemotePrefix(_ ref: String) -> (String?, String) {
        guard let slash = ref.firstIndex(of: "/") else { return (nil, ref) }
        let prefix = String(ref[ref.startIndex..<slash])
        let suffix = String(ref[ref.index(after: slash)...])
        guard !prefix.isEmpty, !suffix.isEmpty else { return (nil, ref) }
        return (prefix, suffix)
    }

    private func duration(from start: Date, to end: Date) -> Double {
        max(0, end.timeIntervalSince(start))
    }

    private func writeLastSync(
        task: TaskName,
        finishedAt: Date,
        resolved: SyncPlan.Resolved,
        appliedCommits: Int,
        durationSeconds: Double
    ) throws {
        let path = workspace.statePath(for: task)
        guard fs.fileExists(at: path) else {
            throw VibeChardError.stateFileCorrupt(
                path: path,
                underlying: "missing — run `vch repair`"
            )
        }
        let data = try fs.readFile(at: path)
        var state = try TaskState.parse(data)
        state.lastSync = TaskState.SyncRecord(
            finishedAt: finishedAt,
            baseSHA: resolved.baseSHA,
            baseLabel: resolved.baseLabel,
            strategy: resolved.strategy.rawValue,
            appliedCommits: appliedCommits,
            durationSeconds: durationSeconds
        )
        try fs.writeFileAtomic(state.jsonData(), to: path)
    }
}
