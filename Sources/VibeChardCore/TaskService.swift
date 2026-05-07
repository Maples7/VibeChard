import Foundation

/// Compact view of a managed task, used by `vch list` and JSON output.
public struct TaskSummary: Equatable, Sendable {
    public let name: String
    public let branch: String
    public let path: String
    public let createdAt: Date?
    public let baseRef: String?
    public let simulatorName: String?
    public let lastBuildSucceeded: Bool?
    public let lastBuildAt: Date?

    public init(
        name: String,
        branch: String,
        path: String,
        createdAt: Date?,
        baseRef: String?,
        simulatorName: String?,
        lastBuildSucceeded: Bool?,
        lastBuildAt: Date?
    ) {
        self.name = name
        self.branch = branch
        self.path = path
        self.createdAt = createdAt
        self.baseRef = baseRef
        self.simulatorName = simulatorName
        self.lastBuildSucceeded = lastBuildSucceeded
        self.lastBuildAt = lastBuildAt
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
    @discardableResult
    public func newTask(
        _ task: TaskName,
        baseRef: String? = nil,
        copyUntracked: Bool = false
    ) throws -> String {
        let wtPath = workspace.worktreePath(for: task)

        if fs.directoryExists(at: wtPath) || fs.fileExists(at: wtPath) {
            throw VibeChardError.worktreeAlreadyExists(path: wtPath)
        }

        if try git.branchExists(repoCwd: workspace.mainWorktreePath, name: task.branchName) {
            throw VibeChardError.worktreeAlreadyExists(path: wtPath)
        }

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
            patterns: [".vch/", ".agent-build/"]
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
            baseBranch: baseBranch
        )
        try fs.writeFileAtomic(state.jsonData(), to: workspace.statePath(for: task))

        if copyUntracked {
            _ = try copyUntrackedFiles(
                from: workspace.mainWorktreePath,
                to: wtPath
            )
        }

        return wtPath
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
        let skipPrefixes = [".vch/", ".agent-build/"]

        var copied = 0
        for rel in entries {
            if rel.isEmpty { continue }
            if rel.hasPrefix("/") { continue }
            if rel.contains("../") || rel == ".." { continue }
            if skipPrefixes.contains(where: { rel.hasPrefix($0) }) { continue }

            let src = "\(sourceWorktree)/\(rel)"
            let dst = "\(destWorktree)/\(rel)"

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

    // MARK: - list

    /// Returns one summary per managed worktree, sorted by `createdAt`
    /// descending (newest first), with stateless worktrees ordered last.
    public func listTasks() throws -> [TaskSummary] {
        let entries = try git.worktreeList(repoCwd: workspace.mainWorktreePath)
        var summaries: [TaskSummary] = []

        for entry in entries {
            // Skip the main worktree itself.
            if entry.path == workspace.mainWorktreePath { continue }
            // Only consider entries whose leaf matches our `<repo>-<task>` pattern.
            guard let raw = workspace.taskNameRaw(forWorktreePath: entry.path) else { continue }

            let statePath = "\(entry.path)/.vch/state.json"
            var state: TaskState? = nil
            if fs.fileExists(at: statePath) {
                if let data = try? fs.readFile(at: statePath) {
                    state = try? TaskState.parse(data)
                }
            }

            summaries.append(TaskSummary(
                name: state?.name ?? raw,
                branch: state?.branch ?? entry.branch ?? "agent/\(raw)",
                path: entry.path,
                createdAt: state?.createdAt,
                baseRef: state?.baseRef,
                simulatorName: state?.simulator?.name,
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

        /// `--force` once → allow dirty.
        public static let forceDirty = RemoveOptions(allowDirty: true, allowUnmergedBranch: false)
        /// `--force` twice → allow dirty + unmerged branch deletion.
        public static let forceAll = RemoveOptions(allowDirty: true, allowUnmergedBranch: true)
    }

    /// Remove a task's worktree and delete its branch. Refuses by
    /// default if the worktree is dirty; pass `allowDirty: true` to
    /// override. Branch deletion uses `git branch -d` first; if the
    /// branch is unmerged, falls back to `git branch -D` only when
    /// `allowUnmergedBranch` is true.
    public func removeTask(_ task: TaskName, options: RemoveOptions = .init()) throws {
        let wtPath = workspace.worktreePath(for: task)
        if !fs.directoryExists(at: wtPath) {
            throw VibeChardError.taskNotFound(name: task.raw)
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
            guard let raw = workspace.taskNameRaw(forWorktreePath: entry.path) else { continue }
            report.checkedTasks.append(raw)

            let statePath = "\(entry.path)/.vch/state.json"
            guard fs.fileExists(at: statePath) else {
                report.problems.append("\(raw): missing .vch/state.json")
                continue
            }
            do {
                let data = try fs.readFile(at: statePath)
                _ = try TaskState.parse(data)
            } catch let err as VibeChardError {
                report.problems.append("\(raw): \(err)")
            } catch {
                report.problems.append("\(raw): \(error)")
            }
        }
        return report
    }
}
