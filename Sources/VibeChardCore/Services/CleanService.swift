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

    public init(
        workspace: Workspace,
        fs: FileSystem = DiskFileSystem(),
        holderScanner: WorktreeHolderScanner? = nil
    ) {
        self.workspace = workspace
        self.fs = fs
        self.holderScanner = holderScanner
    }

    public struct Options: Sendable, Equatable {
        public var includeSwiftPM: Bool
        public var includeLogs: Bool
        public var dryRun: Bool

        public init(
            includeSwiftPM: Bool = false,
            includeLogs: Bool = false,
            dryRun: Bool = false
        ) {
            self.includeSwiftPM = includeSwiftPM
            self.includeLogs = includeLogs
            self.dryRun = dryRun
        }

        /// Convenience: `--all` on the CLI maps here.
        public static let all = Options(
            includeSwiftPM: true,
            includeLogs: true,
            dryRun: false
        )
    }

    public struct Result: Sendable, Equatable {
        public let task: TaskName
        public let dryRun: Bool
        public let removed: [String]
        public let skipped: [String]

        public init(
            task: TaskName,
            dryRun: Bool,
            removed: [String],
            skipped: [String]
        ) {
            self.task = task
            self.dryRun = dryRun
            self.removed = removed
            self.skipped = skipped
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
        if !options.dryRun {
            let blockingHolders = (try? holderScanner?.findHolders(of: wt)) ?? []
            // Filter to holders that touch caches we'd actually
            // delete. An editor at the worktree root or a shell
            // cd'd in shouldn't gate cleanup of `.agent-build/`.
            let managedSubstrings = Workspace.managedDirPrefixes.map { "/\($0)" }
            let blocking = blockingHolders.filter { holder in
                managedSubstrings.contains { holder.samplePath.contains($0) }
            }
            if !blocking.isEmpty {
                throw VibeChardError.cleanBlockedByHolders(
                    task: task.raw,
                    holders: blocking
                )
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
            skipped: skipped
        )
    }
}
