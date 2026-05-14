import Foundation

/// Optional `vch list --git-status` columns for a managed task.
/// Each field is optional so we can degrade gracefully when the
/// underlying git query fails (corrupt repo, missing base branch,
/// detached HEAD, etc.) without ripping the whole row out of the
/// listing.
public struct GitStatus: Equatable, Sendable {
    /// Commits on the task branch that aren't on `baseBranch`.
    /// Nil when the base branch is unknown or `git rev-list` fails.
    public let aheadCount: Int?
    /// Commits on `baseBranch` that aren't on the task branch.
    public let behindCount: Int?
    /// True iff `git status --porcelain` produced any output
    /// (modifications, untracked, deletions). False when status
    /// failed — we don't want a flaky git to lie about "DIRTY".
    public let isDirty: Bool
    /// Subject line of the most recent non-merge commit on the task
    /// branch. Nil if the branch has no non-merge commits or the
    /// query failed.
    public let lastCommitSubject: String?
    /// True iff the task branch is fully merged into its base
    /// (i.e. `aheadCount == 0`). Nil when we couldn't compute it
    /// (no recorded base, git failure, etc.) — distinct from
    /// `false` so the caller can render "unknown" without
    /// pretending the branch is unmerged. Used by `vch list` to
    /// surface a MERGED column and by `vch prune` to pick safe
    /// candidates. (#67)
    public let mergedIntoBase: Bool?

    public init(
        aheadCount: Int?,
        behindCount: Int?,
        isDirty: Bool,
        lastCommitSubject: String?,
        mergedIntoBase: Bool? = nil
    ) {
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.isDirty = isDirty
        self.lastCommitSubject = lastCommitSubject
        self.mergedIntoBase = mergedIntoBase
    }
}

/// Compact view of a managed task, used by `vch list` and JSON output.
public struct TaskSummary: Equatable, Sendable {
    public let name: String
    public let branch: String
    public let path: String
    public let createdAt: Date?
    public let baseRef: String?
    public let baseBranch: String?
    public let simulatorName: String?
    public let lastBuildSucceeded: Bool?
    public let lastBuildAt: Date?
    /// Populated only when the caller asked for `--git-status`. Nil
    /// otherwise so the cheap path stays cheap.
    public let gitStatus: GitStatus?

    public init(
        name: String,
        branch: String,
        path: String,
        createdAt: Date?,
        baseRef: String?,
        baseBranch: String? = nil,
        simulatorName: String?,
        lastBuildSucceeded: Bool?,
        lastBuildAt: Date?,
        gitStatus: GitStatus? = nil
    ) {
        self.name = name
        self.branch = branch
        self.path = path
        self.createdAt = createdAt
        self.baseRef = baseRef
        self.baseBranch = baseBranch
        self.simulatorName = simulatorName
        self.lastBuildSucceeded = lastBuildSucceeded
        self.lastBuildAt = lastBuildAt
        self.gitStatus = gitStatus
    }

    /// Return a copy with `gitStatus` replaced. Lets the CLI enrich
    /// summaries without recomputing the cheap fields.
    public func with(gitStatus: GitStatus?) -> TaskSummary {
        TaskSummary(
            name: name,
            branch: branch,
            path: path,
            createdAt: createdAt,
            baseRef: baseRef,
            baseBranch: baseBranch,
            simulatorName: simulatorName,
            lastBuildSucceeded: lastBuildSucceeded,
            lastBuildAt: lastBuildAt,
            gitStatus: gitStatus
        )
    }
}

/// High-level orchestration for the M1 surface (`vch new` / `list` /
/// `path` / `remove` / `repair`). Wraps a `GitClient`, `FileSystem`, and
/// `Clock` so every behavior is unit-testable without touching disk.
///
/// `TaskService` holds no per-call state; one instance per `vch`
/// invocation is fine.
public struct TaskService: Sendable {
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

    // MARK: - new

    /// Create a fresh worktree + branch + state.json for `task`. Refuses
    /// if the target directory already exists or if the branch already
    /// exists (to keep state consistent). Returns the absolute worktree
    /// path on success.
    ///
    /// When `copyUntracked` is true, also copies every untracked +
    /// non-ignored file from the main worktree into the new worktree.
    /// Useful for files like `.env` and `.vscode/settings.json` that
    /// agents need but that aren't in git.
    ///
    /// When `seedSpmFrom` is non-nil, COW-clones the source task's
    /// SwiftPM bare-mirror cache (`<src>/.agent-build/SwiftPM/
    /// repositories/`) into the new worktree so the first build skips
    /// the network fetch of dependency objects (#55). Only the
    /// `repositories/` subdir is seeded — `checkouts/` is rebuilt
    /// locally on first build because its `.git` config has stale
    /// absolute back-pointers that aren't safe to share.
    @discardableResult
    public func newTask(
        _ task: TaskName,
        baseRef: String? = nil,
        copyUntracked: Bool = false,
        seedSpmFrom: TaskName? = nil
    ) throws -> String {
        let wtPath = workspace.worktreePath(for: task)

        if fs.directoryExists(at: wtPath) || fs.fileExists(at: wtPath) {
            throw VibeChardError.worktreeAlreadyExists(path: wtPath)
        }

        if let existing = try managedWorktreePath(for: task) {
            throw VibeChardError.worktreeAlreadyExists(path: existing)
        }

        if try git.branchExists(repoCwd: workspace.mainWorktreePath, name: task.branchName) {
            throw VibeChardError.worktreeAlreadyExists(path: wtPath)
        }

        // Validate `--seed-spm-from` *before* creating the worktree so
        // a user typo doesn't leave a half-initialised task behind.
        try validateSeedSource(seedSpmFrom)

        // Create the worktree + branch in one shot. Default base = HEAD of main worktree.
        let resolvedBase = baseRef ?? "HEAD"
        try git.worktreeAddNewBranch(
            repoCwd: workspace.mainWorktreePath,
            path: wtPath,
            branch: task.branchName,
            base: resolvedBase
        )

        // Mark `.vch/` and `.agent-build/` as locally ignored so they
        // don't pollute `git status` and trigger spurious "dirty"
        // diagnostics on `vch remove`. Per-worktree only — the user's
        // tracked .gitignore is never touched.
        try? git.appendLocalExcludes(
            worktreeCwd: wtPath,
            patterns: Workspace.managedDirPrefixes
        )

        // Record `baseRef` as the resolved short SHA so `vch list` shows
        // something stable even if the user later moves HEAD.
        let baseShortSHA = (try? git.revParseHEADShort(repoCwd: wtPath)) ?? resolvedBase

        // Record `baseBranch` so `vch land` can default `--into`
        // back to the branch we forked from. May be nil for detached HEAD. (#7)
        let baseBranch = (try? git.currentBranch(repoCwd: workspace.mainWorktreePath)) ?? nil

        try fs.createDirectory(at: workspace.vchDir(for: task))

        let state = TaskState(
            name: task.raw,
            branch: task.branchName,
            createdAt: clock.now(),
            baseRef: baseShortSHA,
            baseBranch: baseBranch,
            worktreeOwnership: .vchCreated
        )
        try fs.writeFileAtomic(state.jsonData(), to: workspace.statePath(for: task))

        if copyUntracked {
            _ = try copyUntrackedFiles(
                from: workspace.mainWorktreePath,
                to: wtPath
            )
        }

        if let src = seedSpmFrom {
            // Both checks already passed up-front; re-resolving paths
            // here keeps the seeding step self-contained.
            let srcRepos = workspace.swiftpmRepositoriesDir(for: src)
            let dstRepos = workspace.swiftpmRepositoriesDir(for: task)
            // Ensure the parent (`<wt>/.agent-build/SwiftPM/`) exists;
            // clonefile(2) requires the parent to be present and the
            // destination itself to NOT be.
            try fs.createDirectory(at: workspace.swiftpmCacheDir(for: task))
            try fs.cloneItem(from: srcRepos, to: dstRepos)
        }

        return wtPath
    }

    /// Register an already-existing linked Git worktree as a vch task.
    /// This intentionally skips `git worktree add` and branch creation:
    /// the caller's tool already created the worktree. vch only writes
    /// its own per-worktree state and scratch layout so build/test/exec
    /// can use the normal isolation paths from this point on.
    @discardableResult
    public func adoptCurrentWorktree(
        _ task: TaskName,
        currentWorktreePath: String,
        baseRef: String? = nil,
        copyUntracked: Bool = false,
        seedSpmFrom: TaskName? = nil
    ) throws -> String {
        let wtPath = try linkedWorktreePathForAdoption(currentWorktreePath)
        guard fs.directoryExists(at: wtPath) else {
            throw VibeChardError.taskNotFound(name: task.raw)
        }

        if let existing = try managedWorktreePath(for: task), existing != wtPath {
            throw VibeChardError.worktreeAlreadyExists(path: existing)
        }

        let existingStatePath = PathOps.join(wtPath, Workspace.stateJsonRelativePath)
        if fs.fileExists(at: existingStatePath) {
            let existingName: String
            if let data = try? fs.readFile(at: existingStatePath),
               let state = try? TaskState.parse(data) {
                existingName = state.name
            } else {
                existingName = "<corrupt>"
            }
            throw VibeChardError.adoptCurrentAlreadyManaged(path: wtPath, name: existingName)
        }

        try validateSeedSource(seedSpmFrom)

        try? git.appendLocalExcludes(
            worktreeCwd: wtPath,
            patterns: Workspace.managedDirPrefixes
        )

        let resolvedBase: String
        if let baseRef {
            resolvedBase = (try? git.revParse(repoCwd: wtPath, ref: baseRef))
                .map { String($0.prefix(7)) } ?? baseRef
        } else {
            resolvedBase = (try? git.revParseHEADShort(repoCwd: workspace.mainWorktreePath)) ?? "HEAD"
        }
        let branch = (try? git.currentBranch(repoCwd: wtPath)) ?? "HEAD"
        let baseBranch = (try? git.currentBranch(repoCwd: workspace.mainWorktreePath)) ?? nil

        try fs.createDirectory(at: PathOps.join(wtPath, ".vch"))
        let state = TaskState(
            name: task.raw,
            branch: branch,
            createdAt: clock.now(),
            baseRef: resolvedBase,
            baseBranch: baseBranch,
            worktreeOwnership: .adopted
        )
        try fs.writeFileAtomic(state.jsonData(), to: existingStatePath)

        if copyUntracked {
            _ = try copyUntrackedFiles(
                from: workspace.mainWorktreePath,
                to: wtPath
            )
        }

        if let src = seedSpmFrom {
            let srcRepos = workspace.swiftpmRepositoriesDir(for: src)
            let effectiveWorkspace = workspace.withWorktreePath(wtPath, for: task)
            let dstRepos = effectiveWorkspace.swiftpmRepositoriesDir(for: task)
            try fs.createDirectory(at: effectiveWorkspace.swiftpmCacheDir(for: task))
            try fs.cloneItem(from: srcRepos, to: dstRepos)
        }

        return wtPath
    }

    /// Default task name for `vch new --adopt-current` when the CLI
    /// omitted `<name>`. The current directory must already be a linked
    /// git worktree, and the worktree directory leaf must satisfy the
    /// normal `TaskName` rules.
    public func inferTaskNameForAdoptCurrent(
        currentWorktreePath: String
    ) throws -> TaskName {
        let wtPath = try linkedWorktreePathForAdoption(currentWorktreePath)
        let leaf = URL(fileURLWithPath: wtPath).lastPathComponent
        return try TaskName(leaf)
    }

    private func linkedWorktreePathForAdoption(
        _ currentWorktreePath: String
    ) throws -> String {
        let wtPath = Workspace(mainWorktreePath: currentWorktreePath).mainWorktreePath
        if wtPath == workspace.mainWorktreePath {
            throw VibeChardError.adoptCurrentRequiresLinkedWorktree(path: wtPath)
        }
        let worktreeEntries = try git.worktreeList(repoCwd: workspace.mainWorktreePath)
        let isLinkedWorktree = worktreeEntries.contains { entry in
            Workspace(mainWorktreePath: entry.path).mainWorktreePath == wtPath
                && wtPath != workspace.mainWorktreePath
        }
        if !isLinkedWorktree {
            throw VibeChardError.adoptCurrentRequiresLinkedWorktree(path: wtPath)
        }
        return wtPath
    }

    private func validateSeedSource(_ seedSpmFrom: TaskName?) throws {
        guard let src = seedSpmFrom else { return }
        let srcWt = workspace.worktreePath(for: src)
        if !fs.directoryExists(at: srcWt) {
            throw VibeChardError.seedSourceTaskNotFound(name: src.raw)
        }
        let srcRepos = workspace.swiftpmRepositoriesDir(for: src)
        if !fs.directoryExists(at: srcRepos) {
            throw VibeChardError.seedSourceHasNoSwiftPMCache(
                name: src.raw,
                expectedPath: srcRepos
            )
        }
    }

    /// Copy every untracked + non-ignored file from `sourceWorktree`
    /// into `destWorktree`, preserving the relative directory layout.
    /// Returns the count of files actually copied. Defensive against
    /// path-escape (`/foo`, `../foo`) and skips vch's own scratch
    /// directories.
    @discardableResult
    func copyUntrackedFiles(
        from sourceWorktree: String,
        to destWorktree: String
    ) throws -> Int {
        let entries = try git.listUntrackedFiles(worktreeCwd: sourceWorktree)
        // Belt-and-braces: `--exclude-standard` should already drop these
        // once `appendLocalExcludes` has been called at least once, but
        // skip them explicitly so a fresh repo's first `vch new` still
        // does the right thing.
        let skipPrefixes = Workspace.managedDirPrefixes

        var copied = 0
        for rel in entries {
            if rel.isEmpty { continue }
            if rel.hasPrefix("/") { continue }
            if rel.contains("../") || rel == ".." { continue }
            if skipPrefixes.contains(where: { rel.hasPrefix($0) }) { continue }

            let src = PathOps.join(sourceWorktree, rel)
            let dst = PathOps.join(destWorktree, rel)

            // Make sure the destination's parent exists; the new
            // worktree only has whatever git checked out, so untracked
            // subdirs may not be there yet.
            let parent = (dst as NSString).deletingLastPathComponent
            try fs.createDirectory(at: parent)

            // If something already lives at `dst` (e.g. a tracked file
            // happens to share a name with a transient untracked one
            // because of a symlinked layout), don't clobber it.
            if fs.fileExists(at: dst) || fs.directoryExists(at: dst) { continue }

            try fs.copyItem(from: src, to: dst)
            copied += 1
        }
        return copied
    }

    private func managedWorktreePath(for task: TaskName) throws -> String? {
        let entries = try git.worktreeList(repoCwd: workspace.mainWorktreePath)
        for entry in entries {
            if entry.path == workspace.mainWorktreePath { continue }

            let statePath = PathOps.join(entry.path, Workspace.stateJsonRelativePath)
            if fs.fileExists(at: statePath),
               let data = try? fs.readFile(at: statePath),
               let state = try? TaskState.parse(data),
               state.name == task.raw {
                return entry.path
            }

            if workspace.taskNameRaw(forWorktreePath: entry.path) == task.raw {
                return entry.path
            }
        }
        return nil
    }

    // MARK: - list

    /// Returns one summary per managed worktree, sorted by `createdAt`
    /// descending (newest first), with stateless worktrees ordered last.
    public func listTasks() throws -> [TaskSummary] {
        let entries = try git.worktreeList(repoCwd: workspace.mainWorktreePath)
        var summaries: [TaskSummary] = []

        for entry in entries {
            // Skip the main worktree itself.
            if entry.path == workspace.mainWorktreePath { continue }

            let statePath = PathOps.join(entry.path, Workspace.stateJsonRelativePath)
            var state: TaskState? = nil
            if fs.fileExists(at: statePath) {
                if let data = try? fs.readFile(at: statePath) {
                    state = try? TaskState.parse(data)
                }
            }

            let raw: String
            if let state {
                raw = state.name
            } else if let inferred = workspace.taskNameRaw(forWorktreePath: entry.path) {
                raw = inferred
            } else {
                continue
            }

            summaries.append(TaskSummary(
                name: state?.name ?? raw,
                branch: state?.branch ?? entry.branch ?? "agent/\(raw)",
                path: entry.path,
                createdAt: state?.createdAt,
                baseRef: state?.baseRef,
                baseBranch: state?.baseBranch,
                simulatorName: Self.summarize(simulators: state?.allSimulators ?? []),
                lastBuildSucceeded: state?.lastBuild?.success,
                lastBuildAt: state?.lastBuild?.finishedAt
            ))
        }

        return summaries.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?): return l > r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs.name < rhs.name
            }
        }
    }

    /// Compute the optional `--git-status` columns (#24) for one
    /// summary. Each git query is best-effort: a transient git
    /// failure degrades the matching field to `nil` instead of
    /// erroring the whole `vch list`.
    ///
    /// `aheadCount` / `behindCount` need a base branch to compare
    /// against. Source order: `summary.baseBranch` (recorded by
    /// `vch new` when the main worktree had a checked-out branch),
    /// then `summary.baseRef` (a short SHA, used as a literal commit
    /// pointer), else nil.
    public func gitStatus(forSummary summary: TaskSummary) -> GitStatus {
        let wt = summary.path
        let isDirty = (try? git.statusIsDirty(worktreeCwd: wt)) ?? false
        let subject = (try? git.lastNonMergeSubject(repoCwd: wt, branch: "HEAD")) ?? nil

        let base: String? = summary.baseBranch ?? summary.baseRef
        var ahead: Int? = nil
        var behind: Int? = nil
        if let base, !base.isEmpty {
            ahead  = try? git.revListCount(repoCwd: wt, base: base, head: "HEAD")
            behind = try? git.revListCount(repoCwd: wt, base: "HEAD", head: base)
        }
        // "Fully merged" = no commits on the task branch that
        // aren't already on its base. This is the same shape `git
        // branch --merged` uses, but driven off the per-task
        // baseBranch we recorded in state.json so the answer
        // doesn't depend on which branch the main worktree
        // happens to have checked out right now. (#67)
        let merged: Bool? = ahead.map { $0 == 0 }
        return GitStatus(
            aheadCount: ahead,
            behindCount: behind,
            isDirty: isDirty,
            lastCommitSubject: subject,
            mergedIntoBase: merged
        )
    }

    // MARK: - path

    /// Resolve the absolute path of a task's worktree. Throws
    /// `taskNotFound` if the directory does not exist.
    public func pathForTask(_ task: TaskName) throws -> String {
        let p = workspace.worktreePath(for: task)
        if !fs.directoryExists(at: p) {
            throw VibeChardError.taskNotFound(name: task.raw)
        }
        return p
    }

    // MARK: - state

    /// Read and parse `<wt>/.vch/state.json` for a task. Throws
    /// `taskNotFound` if the worktree does not exist, or
    /// `stateFileMissing` / `stateFileCorrupt` if the file is gone or
    /// malformed.
    public func stateForTask(_ task: TaskName) throws -> TaskState {
        let wtPath = workspace.worktreePath(for: task)
        if !fs.directoryExists(at: wtPath) {
            throw VibeChardError.taskNotFound(name: task.raw)
        }
        let statePath = workspace.statePath(for: task)
        if !fs.fileExists(at: statePath) {
            throw VibeChardError.stateFileMissing(path: statePath)
        }
        let data = try fs.readFile(at: statePath)
        do {
            return try TaskState.parse(data)
        } catch VibeChardError.stateFileCorrupt(_, let underlying) {
            // Re-throw with the actual filesystem path for better
            // diagnostics — `TaskState.parse` only knows "<in-memory>".
            throw VibeChardError.stateFileCorrupt(path: statePath, underlying: underlying)
        }
    }

    // MARK: - remove

    public struct RemoveOptions: Sendable {
        /// Allow removing a worktree with uncommitted changes.
        public let allowDirty: Bool
        /// Force-delete the branch even if not fully merged (`git branch -D`).
        public let allowUnmergedBranch: Bool

        public init(allowDirty: Bool = false, allowUnmergedBranch: Bool = false) {
            self.allowDirty = allowDirty
            self.allowUnmergedBranch = allowUnmergedBranch
        }

        /// Allow dirty worktree only.
        public static let forceDirty = RemoveOptions(allowDirty: true, allowUnmergedBranch: false)
        /// Allow dirty worktree and unmerged-branch deletion.
        public static let forceAll = RemoveOptions(allowDirty: true, allowUnmergedBranch: true)
    }

    /// Remove a task. vch-created tasks remove the Git worktree and
    /// `agent/<name>` branch. Adopted tasks only unregister vch by
    /// deleting vch-owned scratch directories; the externally-created
    /// Git worktree and branch remain owned by the tool/user that made
    /// them.
    public func removeTask(_ task: TaskName, options: RemoveOptions = .init()) throws {
        let wtPath = workspace.worktreePath(for: task)
        if !fs.directoryExists(at: wtPath) {
            throw VibeChardError.taskNotFound(name: task.raw)
        }

        let state = try? stateForTask(task)
        if state?.worktreeOwnership == .adopted {
            try removeAdoptedTaskArtifacts(task)
            return
        }

        if !options.allowDirty {
            let dirty = (try? git.statusIsDirty(worktreeCwd: wtPath)) ?? false
            if dirty {
                throw VibeChardError.dirtyWorktree(path: wtPath)
            }
        }

        try git.worktreeRemove(repoCwd: workspace.mainWorktreePath, path: wtPath, force: options.allowDirty)

        // Delete the branch we created. If it doesn't exist anymore (user
        // already removed it), silently continue.
        let branch = task.branchName
        let exists = (try? git.branchExists(repoCwd: workspace.mainWorktreePath, name: branch)) ?? false
        guard exists else { return }

        do {
            try git.branchDelete(repoCwd: workspace.mainWorktreePath, name: branch)
        } catch VibeChardError.unmergedBranch {
            if options.allowUnmergedBranch {
                try git.branchDeleteForce(repoCwd: workspace.mainWorktreePath, name: branch)
            } else {
                throw VibeChardError.unmergedBranch(name: branch)
            }
        }
    }

    private func removeAdoptedTaskArtifacts(_ task: TaskName) throws {
        let vchDir = workspace.vchDir(for: task)
        if fs.directoryExists(at: vchDir) || fs.fileExists(at: vchDir) {
            try fs.removeItem(at: vchDir)
        }
        let buildDir = workspace.agentBuildDir(for: task)
        if fs.directoryExists(at: buildDir) || fs.fileExists(at: buildDir) {
            try fs.removeItem(at: buildDir)
        }
    }

    // MARK: - repair

    public struct RepairReport: Equatable, Sendable {
        public var prunedStaleEntries: Bool
        public var checkedTasks: [String]
        public var problems: [String]

        public init(prunedStaleEntries: Bool = false, checkedTasks: [String] = [], problems: [String] = []) {
            self.prunedStaleEntries = prunedStaleEntries
            self.checkedTasks = checkedTasks
            self.problems = problems
        }
    }

    /// Run `git worktree prune`, then walk every managed worktree and
    /// surface any `.vch/state.json` files we cannot read or that have
    /// the wrong schema. Best-effort: never throws on individual issues,
    /// just collects them in the report.
    public func repair() throws -> RepairReport {
        var report = RepairReport()
        try git.worktreePrune(repoCwd: workspace.mainWorktreePath)
        report.prunedStaleEntries = true

        let entries = try git.worktreeList(repoCwd: workspace.mainWorktreePath)
        for entry in entries {
            if entry.path == workspace.mainWorktreePath { continue }

            let statePath = PathOps.join(entry.path, Workspace.stateJsonRelativePath)
            if fs.fileExists(at: statePath) {
                do {
                    let data = try fs.readFile(at: statePath)
                    let state = try TaskState.parse(data)
                    report.checkedTasks.append(state.name)
                } catch let err as VibeChardError {
                    let raw = workspace.taskNameRaw(forWorktreePath: entry.path)
                        ?? URL(fileURLWithPath: entry.path).lastPathComponent
                    report.checkedTasks.append(raw)
                    report.problems.append("\(raw): \(err)")
                } catch {
                    let raw = workspace.taskNameRaw(forWorktreePath: entry.path)
                        ?? URL(fileURLWithPath: entry.path).lastPathComponent
                    report.checkedTasks.append(raw)
                    report.problems.append("\(raw): \(error)")
                }
                continue
            }

            guard let raw = workspace.taskNameRaw(forWorktreePath: entry.path) else { continue }
            report.checkedTasks.append(raw)
            guard fs.fileExists(at: statePath) else {
                report.problems.append("\(raw): missing \(Workspace.stateJsonRelativePath)")
                continue
            }
        }
        return report
    }

    /// Compact display string for the simulator column of `vch list`
    /// (#99). With 0 bindings → nil; 1 binding → that name; 2+
    /// bindings → `"<first> (+N)"` so the column stays narrow while
    /// still telling the user the task has extra clones.
    static func summarize(simulators records: [TaskState.SimulatorRecord]) -> String? {
        switch records.count {
        case 0: return nil
        case 1: return records[0].name
        default: return "\(records[0].name) (+\(records.count - 1))"
        }
    }
}
