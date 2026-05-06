import Foundation

/// Builds an `ExecPlan` for `vch exec <name> -- <cmd...>`. Performs
/// the side-effects (mkdir, symlink) needed by the time the child
/// runs, but does NOT spawn any process — that lives in the CLI layer
/// where signal handling sits.
///
/// The child sees:
///   • cwd    = the task's worktree path
///   • PATH   = `<wt>/.vch/bin` prepended to `baseEnv["PATH"]`
///   • shim-side env: `VCH_DERIVED_DATA_PATH`, `VCH_SPM_CLONE_DIR`,
///     `VCH_RESULT_BUNDLE_PATH` — read by `vch-xcodebuild-shim` to
///     inject xcodebuild flags.
///   • tool-side env: `CLANG_MODULE_CACHE_PATH`, `SWIFTPM_CACHE_DIR`
///     — honored directly by clang / SwiftPM, so isolation survives
///     even when the shim is bypassed.
///   • descriptive env: `VCH_TASK_NAME`, `VCH_TASK_ROOT`,
///     `VCH_RESULT_BUNDLE_DIR` — used by Q12 shellenv helpers and
///     downstream agent scripts.
public struct ExecService: Sendable {
    public let workspace: Workspace
    public let git: GitClient
    public let fs: FileSystem

    public init(
        workspace: Workspace,
        git: GitClient,
        fs: FileSystem = DiskFileSystem()
    ) {
        self.workspace = workspace
        self.git = git
        self.fs = fs
    }

    /// Names of the three shim symlinks we install into `<wt>/.vch/bin/`.
    /// The shim dispatches on its own argv[0], so all three point at
    /// the same binary.
    public static let shimSymlinkNames = ["xcodebuild", "xcrun", "swift"]

    /// Build (and materialize side-effects for) an `ExecPlan`.
    ///
    /// - Parameters:
    ///   - task: validated task name.
    ///   - command: argv to run inside the worktree (must be non-empty).
    ///   - shimPath: absolute path to `vch-xcodebuild-shim`. Symlinks
    ///     are created idempotently in `<wt>/.vch/bin/`.
    ///   - baseEnv: typically `ProcessInfo.processInfo.environment`.
    public func prepare(
        task: TaskName,
        command: [String],
        shimPath: String,
        baseEnv: [String: String]
    ) throws -> ExecPlan {
        guard !command.isEmpty else {
            throw VibeChardError.missingArgument(
                "command (use `vch exec <name> -- <cmd> [args...]`)"
            )
        }
        let wt = workspace.worktreePath(for: task)
        if !fs.directoryExists(at: wt) {
            throw VibeChardError.taskNotFound(name: task.raw)
        }

        // Create the dirs the shim and downstream tools will write into.
        try fs.createDirectory(at: workspace.vchBinDir(for: task))
        try fs.createDirectory(at: workspace.derivedDataDir(for: task))
        try fs.createDirectory(at: workspace.swiftpmCacheDir(for: task))
        try fs.createDirectory(at: workspace.moduleCacheDir(for: task))

        // Idempotent shim install.
        var installed: [String] = []
        let binDir = workspace.vchBinDir(for: task)
        for name in Self.shimSymlinkNames {
            let linkPath = (binDir as NSString).appendingPathComponent(name)
            try fs.createSymbolicLink(at: linkPath, withDestination: shimPath)
            installed.append(linkPath)
        }

        let env = buildEnv(task: task, worktree: wt, baseEnv: baseEnv)

        return ExecPlan(
            cwd: wt,
            argv: command,
            env: env,
            installedShimSymlinks: installed
        )
    }

    /// Pure helper: derive the child's environment from `baseEnv`.
    /// Exposed for unit tests.
    public func buildEnv(
        task: TaskName,
        worktree: String,
        baseEnv: [String: String]
    ) -> [String: String] {
        var env = baseEnv

        // Prepend `<wt>/.vch/bin` to PATH so the shim symlinks resolve
        // first. We never overwrite the user's PATH wholesale.
        let binDir = workspace.vchBinDir(for: task)
        let originalPath = baseEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(binDir):\(originalPath)"

        // Shim-side: read by vch-xcodebuild-shim (M2).
        env["VCH_DERIVED_DATA_PATH"] = workspace.derivedDataDir(for: task)
        env["VCH_SPM_CLONE_DIR"]     = workspace.swiftpmCacheDir(for: task)
        env["VCH_RESULT_BUNDLE_PATH"] = workspace.resultBundlePath(for: task)

        // Tool-side: honored by clang and SwiftPM directly. Provides a
        // second layer of isolation if a tool runs without the shim
        // on PATH.
        env["CLANG_MODULE_CACHE_PATH"] = workspace.moduleCacheDir(for: task)
        env["SWIFTPM_CACHE_DIR"]       = workspace.swiftpmCacheDir(for: task)

        // Descriptive: useful for AGENTS.md scripts and Q12 helpers.
        env["VCH_TASK_NAME"] = task.raw
        env["VCH_TASK_ROOT"] = worktree
        env["VCH_RESULT_BUNDLE_DIR"] =
            (workspace.resultBundlePath(for: task) as NSString).deletingLastPathComponent

        return env
    }
}
