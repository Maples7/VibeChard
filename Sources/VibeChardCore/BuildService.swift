import Foundation

/// Outcome of a build/test run that the CLI hands back to Core to
/// persist into `.vch/state.json`.
public struct BuildOutcome: Equatable, Sendable {
    public let success: Bool
    public let durationSeconds: Double
    public let finishedAt: Date

    public init(success: Bool, durationSeconds: Double, finishedAt: Date) {
        self.success = success
        self.durationSeconds = durationSeconds
        self.finishedAt = finishedAt
    }
}

/// `vch build` / `vch test` orchestration. Like `ExecService`, this is
/// a pure planner: it materializes the on-disk side-effects vch must
/// own (mkdir of scratch dirs, optional shim symlinks) and returns an
/// `ExecPlan`. The CLI launches the plan and reports back via
/// `recordBuild` / `recordTest`.
public struct BuildService: Sendable {
    public let workspace: Workspace
    public let fs: FileSystem

    public init(
        workspace: Workspace,
        fs: FileSystem = DiskFileSystem()
    ) {
        self.workspace = workspace
        self.fs = fs
    }

    public struct Options: Sendable {
        public var scheme: String?
        public var configuration: String?
        public var device: String?
        public var extraArgs: [String]

        public init(
            scheme: String? = nil,
            configuration: String? = nil,
            device: String? = nil,
            extraArgs: [String] = []
        ) {
            self.scheme = scheme
            self.configuration = configuration
            self.device = device
            self.extraArgs = extraArgs
        }
    }

    // MARK: - prepare

    public func prepareBuild(
        task: TaskName,
        options: Options,
        baseEnv: [String: String]
    ) throws -> ExecPlan {
        try preparePlan(task: task, action: "build", options: options,
                        emitsResultBundle: false, baseEnv: baseEnv)
    }

    public func prepareTest(
        task: TaskName,
        options: Options,
        baseEnv: [String: String]
    ) throws -> ExecPlan {
        try preparePlan(task: task, action: "test", options: options,
                        emitsResultBundle: true, baseEnv: baseEnv)
    }

    private func preparePlan(
        task: TaskName,
        action: String,
        options: Options,
        emitsResultBundle: Bool,
        baseEnv: [String: String]
    ) throws -> ExecPlan {
        let wt = workspace.worktreePath(for: task)
        if !fs.directoryExists(at: wt) {
            throw VibeChardError.taskNotFound(name: task.raw)
        }

        // Same scratch tree ExecService creates. We only need DerivedData
        // / SwiftPM / ModuleCache here — no shim symlinks (M4 invokes
        // xcodebuild directly per Q-decision "direct, not via shim").
        try fs.createDirectory(at: workspace.derivedDataDir(for: task))
        try fs.createDirectory(at: workspace.swiftpmCacheDir(for: task))
        try fs.createDirectory(at: workspace.moduleCacheDir(for: task))
        if emitsResultBundle {
            // resultBundle path itself must NOT exist (xcodebuild
            // refuses to overwrite). Wipe a stale one if it's there;
            // create only the parent dir.
            let bundle = workspace.resultBundlePath(for: task)
            if fs.fileExists(at: bundle) || fs.directoryExists(at: bundle) {
                try fs.removeItem(at: bundle)
            }
        }

        let argv = ["xcodebuild"] + BuildPlanner.args(.init(
            action: action,
            scheme: options.scheme,
            configuration: options.configuration,
            derivedDataPath: workspace.derivedDataDir(for: task),
            clonedSourcePackagesDir: workspace.swiftpmCacheDir(for: task),
            resultBundlePath: emitsResultBundle ? workspace.resultBundlePath(for: task) : nil,
            destinationDevice: options.device,
            extraArgs: options.extraArgs
        ))

        var env = baseEnv
        // Tool-side isolation. We do NOT set the shim-side `VCH_*`
        // vars here — the shim isn't on PATH for M4 invocations and
        // the equivalent flags are already in argv.
        env["CLANG_MODULE_CACHE_PATH"] = workspace.moduleCacheDir(for: task)
        env["SWIFTPM_CACHE_DIR"]       = workspace.swiftpmCacheDir(for: task)
        // Descriptive (matches ExecService set so AGENTS.md scripts are
        // uniform whether invoked via vch exec or vch build/test).
        env["VCH_TASK_NAME"]           = task.raw
        env["VCH_TASK_ROOT"]           = wt
        env["VCH_RESULT_BUNDLE_DIR"]   =
            (workspace.resultBundlePath(for: task) as NSString).deletingLastPathComponent

        return ExecPlan(cwd: wt, argv: argv, env: env, installedShimSymlinks: [])
    }

    // MARK: - record outcome

    /// Persist a build outcome into `.vch/state.json`. Reads the
    /// current state, mutates `lastBuild`, writes atomically. If the
    /// file is missing or corrupt we surface the same errors `vch
    /// repair` would — refusing to silently overwrite garbage.
    public func recordBuild(task: TaskName, outcome: BuildOutcome,
                            scheme: String?) throws {
        try mutateState(task: task) { state in
            if let scheme { state.scheme = scheme }
            state.lastBuild = TaskState.BuildRecord(
                finishedAt: outcome.finishedAt,
                durationSeconds: outcome.durationSeconds,
                success: outcome.success
            )
        }
    }

    public func recordTest(task: TaskName, outcome: BuildOutcome,
                           scheme: String?) throws {
        try mutateState(task: task) { state in
            if let scheme { state.scheme = scheme }
            state.lastTest = TaskState.TestRecord(
                finishedAt: outcome.finishedAt,
                durationSeconds: outcome.durationSeconds,
                success: outcome.success,
                resultBundlePath: workspace.resultBundlePath(for: task)
            )
        }
    }

    private func mutateState(
        task: TaskName,
        _ mutation: (inout TaskState) -> Void
    ) throws {
        let path = workspace.statePath(for: task)
        guard fs.fileExists(at: path) else {
            throw VibeChardError.stateFileCorrupt(
                path: path,
                underlying: "missing — run `vch repair`"
            )
        }
        let data = try fs.readFile(at: path)
        var state: TaskState
        do {
            state = try TaskState.parse(data)
        } catch {
            throw error
        }
        mutation(&state)
        try fs.writeFileAtomic(state.jsonData(), to: path)
    }
}
