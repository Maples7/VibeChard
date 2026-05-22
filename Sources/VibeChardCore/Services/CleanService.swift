import Foundation

/// `vch clean <name>` — wipe per-task scratch caches.
///
/// Hard rules (issue #26):
///   • Never touches git-tracked files (we only operate inside
///     `<wt>/.agent-build/` and named log files in `<wt>/.vch/`).
///   • Never touches simulator clones (those live outside the worktree).
///   • Refuses if a process is holding files inside the worktree's
///     `.agent-build/` or `.vch/` (i.e. `vch build` / `xcodebuild`
///     mid-flight). `--dry-run` skips the check.
///   • Idempotent — non-existent targets are reported as "skipped",
///     not errors; calling twice yields exit 0 the second time.
public struct CleanService: Sendable {
    public let workspace: Workspace
    public let fs: FileSystem
    /// Optional holder scanner for the mid-flight check. Nil disables
    /// the check (used in unit tests where lsof isn't available, and
    /// the very first time a worktree is created so we don't shell
    /// out unnecessarily).
    public let holderScanner: WorktreeHolderScanner?
    public let testProcessScanner: TestSessionProcessScanner?
    public let processTerminator: ProcessTerminator?

    public init(
        workspace: Workspace,
        fs: FileSystem = DiskFileSystem(),
        holderScanner: WorktreeHolderScanner? = nil,
        testProcessScanner: TestSessionProcessScanner? = nil,
        processTerminator: ProcessTerminator? = nil
    ) {
        self.workspace = workspace
        self.fs = fs
        self.holderScanner = holderScanner
        self.testProcessScanner = testProcessScanner
        self.processTerminator = processTerminator
    }

    public struct Options: Sendable, Equatable {
        public var includeSwiftPM: Bool
        public var includeLogs: Bool
        public var dryRun: Bool
        public var killStuckTests: Bool

        public init(
            includeSwiftPM: Bool = false,
            includeLogs: Bool = false,
            dryRun: Bool = false,
            killStuckTests: Bool = false
        ) {
            self.includeSwiftPM = includeSwiftPM
            self.includeLogs = includeLogs
            self.dryRun = dryRun
            self.killStuckTests = killStuckTests
        }

        /// Convenience: `--all` on the CLI maps here.
        public static let all = Options(
            includeSwiftPM: true,
            includeLogs: true,
            dryRun: false,
            killStuckTests: false
        )
    }

    public struct Result: Sendable, Equatable {
        public let task: TaskName
        public let dryRun: Bool
        public let removed: [String]
        public let skipped: [String]
        public let terminatedTestProcesses: [TestSessionProcess]
        public let terminatedStuckHolders: [WorktreeHolder]

        public init(
            task: TaskName,
            dryRun: Bool,
            removed: [String],
            skipped: [String],
            terminatedTestProcesses: [TestSessionProcess] = [],
            terminatedStuckHolders: [WorktreeHolder] = []
        ) {
            self.task = task
            self.dryRun = dryRun
            self.removed = removed
            self.skipped = skipped
            self.terminatedTestProcesses = terminatedTestProcesses
            self.terminatedStuckHolders = terminatedStuckHolders
        }
    }

    /// Compute the set of paths to clean for this task + options.
    /// Order is stable (DerivedData → ModuleCache → SwiftPM → logs)
    /// so test assertions can compare directly.
    public func targets(
        for task: TaskName,
        options: Options
    ) -> [String] {
        var paths: [String] = [
            workspace.derivedDataDir(for: task),
            workspace.moduleCacheDir(for: task),
        ]
        if options.includeSwiftPM {
            paths.append(workspace.swiftpmCacheDir(for: task))
        }
        if options.includeLogs {
            paths.append(workspace.lastTestLogPath(for: task))
        }
        return paths
    }

    public func clean(
        task: TaskName,
        options: Options
    ) throws -> Result {
        let wt = workspace.worktreePath(for: task)
        guard fs.directoryExists(at: wt) else {
            throw VibeChardError.taskNotFound(name: task.raw)
        }

        // Mid-flight check: only block when actually deleting. A
        // `--dry-run` should always succeed so users can plan a
        // cleanup ahead of a build finishing.
        var terminatedTestProcesses: [TestSessionProcess] = []
        var terminatedStuckHolders: [WorktreeHolder] = []
        if !options.dryRun {
            let stuckTestProcesses = findStuckTestProcesses(task: task)
            if !stuckTestProcesses.isEmpty {
                guard options.killStuckTests, let processTerminator else {
                    throw VibeChardError.cleanBlockedByTestSession(
                        task: task.raw,
                        processes: stuckTestProcesses
                    )
                }
                for process in stuckTestProcesses {
                    try processTerminator.terminate(pid: process.pid)
                    terminatedTestProcesses.append(process)
                }
            }

            let blocking = blockingManagedHolders(in: wt)
            if !blocking.isEmpty {
                guard options.killStuckTests, let processTerminator else {
                    throw VibeChardError.cleanBlockedByHolders(
                        task: task.raw,
                        holders: blocking
                    )
                }

                let killable = blocking.filter(isKillableStuckHolder)
                guard !killable.isEmpty else {
                    throw VibeChardError.cleanBlockedByHolders(
                        task: task.raw,
                        holders: blocking
                    )
                }
                for holder in killable {
                    try processTerminator.terminate(pid: holder.pid)
                    terminatedStuckHolders.append(holder)
                }

                let remaining = blockingManagedHolders(in: wt)
                if !remaining.isEmpty {
                    throw VibeChardError.cleanBlockedByHolders(
                        task: task.raw,
                        holders: remaining
                    )
                }
            }
        }

        var removed: [String] = []
        var skipped: [String] = []
        for path in targets(for: task, options: options) {
            let exists = fs.directoryExists(at: path) || fs.fileExists(at: path)
            guard exists else {
                skipped.append(path)
                continue
            }
            if options.dryRun {
                removed.append(path)
            } else {
                try fs.removeItem(at: path)
                removed.append(path)
            }
        }
        return Result(
            task: task,
            dryRun: options.dryRun,
            removed: removed,
            skipped: skipped,
            terminatedTestProcesses: terminatedTestProcesses,
            terminatedStuckHolders: terminatedStuckHolders
        )
    }

    private func blockingManagedHolders(in worktreePath: String) -> [WorktreeHolder] {
        let holders = (try? holderScanner?.findHolders(of: worktreePath)) ?? []
        // Filter to holders that touch caches we'd actually delete.
        // An editor at the worktree root or a shell cd'd in shouldn't
        // gate cleanup of `.agent-build/`.
        let managedSubstrings = Workspace.managedDirPrefixes.map { "/\($0)" }
        return holders.filter { holder in
            managedSubstrings.contains { holder.samplePath.contains($0) }
        }
    }

    private func isKillableStuckHolder(_ holder: WorktreeHolder) -> Bool {
        let command = holder.command.lowercased()
        return ["xcodebuild", "swbbuildservice", "xctest", "xctrunner"].contains { command.contains($0) }
    }

    private func findStuckTestProcesses(task: TaskName) -> [TestSessionProcess] {
        guard let testProcessScanner else { return [] }
        let state = lastKnownState(for: task)
        let query = TestSessionProcessQuery(
            taskName: task.raw,
            worktreePath: workspace.worktreePath(for: task),
            derivedDataPath: workspace.derivedDataDir(for: task),
            resultBundlePath: workspace.resultBundlePath(for: task),
            scheme: state?.scheme,
            simulatorUDIDs: state?.allSimulators.map(\.cloneUDID) ?? []
        )
        return (try? testProcessScanner.findProcesses(for: query)) ?? []
    }

    private func lastKnownState(for task: TaskName) -> TaskState? {
        let path = workspace.statePath(for: task)
        guard fs.fileExists(at: path),
              let data = try? fs.readFile(at: path),
              let state = try? TaskState.parse(data) else {
            return nil
        }
        return state
    }
}
