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

/// `vch build` / `vch test` orchestration. The prepare methods
/// materialize the on-disk side-effects vch must own (mkdir of scratch
/// dirs, optional shim symlinks) and return an `ExecPlan`. The CLI
/// launches the plan and reports back via `recordBuild` / `recordTest`.
public struct BuildService: Sendable {
    public let workspace: Workspace
    public let fs: FileSystem
    public let simulator: SimulatorService?
    /// Resolver for `DEVELOPER_DIR` injection (#31). Nil in unit tests
    /// so plans stay deterministic; the CLI passes a real one.
    public let developerDir: DeveloperDirResolver?
    /// Optional build-settings probe used to infer the scheme's
    /// simulator platform before reusing an existing clone.
    public let settingsLister: BuildSettingsLister?

    public init(
        workspace: Workspace,
        fs: FileSystem = DiskFileSystem(),
        simulator: SimulatorService? = nil,
        developerDir: DeveloperDirResolver? = nil,
        settingsLister: BuildSettingsLister? = nil
    ) {
        self.workspace = workspace
        self.fs = fs
        self.simulator = simulator
        self.developerDir = developerDir
        self.settingsLister = settingsLister
    }

    public struct Options: Sendable {
        public var scheme: String?
        public var xcodebuildContainer: XcodebuildContainer?
        public var configuration: String?
        public var device: String?
        public var runtime: String?
        public var destinationPlatform: SimRuntimeVersion.Platform?
        /// Opt out of the M5 lazy clone. When true, `--device` (if set)
        /// is forwarded as `name=<device>` and no `simctl clone`
        /// happens.
        public var noSim: Bool
        public var extraArgs: [String]

        public init(
            scheme: String? = nil,
            xcodebuildContainer: XcodebuildContainer? = nil,
            configuration: String? = nil,
            device: String? = nil,
            runtime: String? = nil,
            destinationPlatform: SimRuntimeVersion.Platform? = nil,
            noSim: Bool = false,
            extraArgs: [String] = []
        ) {
            self.scheme = scheme
            self.xcodebuildContainer = xcodebuildContainer
            self.configuration = configuration
            self.device = device
            self.runtime = runtime
            self.destinationPlatform = destinationPlatform
            self.noSim = noSim
            self.extraArgs = extraArgs
        }
    }

    // MARK: - prepare

    public func prepareBuild(
        task: TaskName,
        options: Options,
        resolvedSimulatorUDID: String? = nil,
        resolvedSimulatorPlatform: SimRuntimeVersion.Platform? = nil,
        baseEnv: [String: String]
    ) throws -> ExecPlan {
        try preparePlan(task: task, action: "build", options: options,
                        emitsResultBundle: false,
                        resolvedSimulatorUDID: resolvedSimulatorUDID,
                        resolvedSimulatorPlatform: resolvedSimulatorPlatform,
                        baseEnv: baseEnv)
    }

    public func prepareTest(
        task: TaskName,
        options: Options,
        resolvedSimulatorUDID: String? = nil,
        resolvedSimulatorPlatform: SimRuntimeVersion.Platform? = nil,
        baseEnv: [String: String]
    ) throws -> ExecPlan {
        try preparePlan(task: task, action: "test", options: options,
                        emitsResultBundle: true,
                        resolvedSimulatorUDID: resolvedSimulatorUDID,
                        resolvedSimulatorPlatform: resolvedSimulatorPlatform,
                        baseEnv: baseEnv)
    }

    private func preparePlan(
        task: TaskName,
        action: String,
        options: Options,
        emitsResultBundle: Bool,
        resolvedSimulatorUDID: String?,
        resolvedSimulatorPlatform: SimRuntimeVersion.Platform?,
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

        let destinationPlatform: SimRuntimeVersion.Platform
        if let resolvedSimulatorUDID {
            guard let platform = resolvedSimulatorPlatform else {
                throw VibeChardError.simulatorPlatformUnknown(
                    udid: resolvedSimulatorUDID,
                    name: resolvedSimulatorUDID
                )
            }
            destinationPlatform = platform
        } else {
            destinationPlatform = options.destinationPlatform
                ?? options.runtime.flatMap { SimRuntimeVersion.parse(runtimeLabel: $0)?.platform }
                ?? .iOS
        }

        // Destination resolution priority:
        //   1. resolvedSimulatorUDID (M5: per-task clone) → `id=<UDID>`
        //   2. else options.device                       → `name=<device>`
        //   3. else no -destination                       (host build)
        let argv = ["xcodebuild"] + BuildPlanner.args(.init(
            action: action,
            xcodebuildContainer: options.xcodebuildContainer,
            scheme: options.scheme,
            configuration: options.configuration,
            derivedDataPath: workspace.derivedDataDir(for: task),
            clonedSourcePackagesDir: workspace.swiftpmCacheDir(for: task),
            resultBundlePath: emitsResultBundle ? workspace.resultBundlePath(for: task) : nil,
            destinationUDID: resolvedSimulatorUDID,
            destinationPlatform: destinationPlatform,
            destinationDevice: resolvedSimulatorUDID == nil ? options.device : nil,
            extraArgs: options.extraArgs
        ))

        var env = baseEnv
        // Tool-side isolation. We do NOT set the shim-side `VCH_*`
        // vars here — the shim isn't on PATH for M4 invocations and
        // the equivalent flags are already in argv.
        env["CLANG_MODULE_CACHE_PATH"] = workspace.moduleCacheDir(for: task)
        env["SWIFTPM_CACHE_DIR"]       = workspace.swiftpmCacheDir(for: task)
        // M5: pin child simctl invocations (tests, embedded scripts) to
        // the per-task clone so they don't bleed into the user's
        // default booted device.
        if let udid = resolvedSimulatorUDID {
            env["SIMCTL_CHILD_SIMULATOR_UDID"] = udid
        }
        // Descriptive (matches ExecService set so AGENTS.md scripts are
        // uniform whether invoked via vch exec or vch build/test).
        env["VCH_TASK_NAME"]           = task.raw
        env["VCH_TASK_ROOT"]           = wt
        env["VCH_RESULT_BUNDLE_DIR"]   =
            (workspace.resultBundlePath(for: task) as NSString).deletingLastPathComponent
        // #31: pin the toolchain root so a hand-typed xcrun inside a
        // `vch <name>` sugar shell hits the same Xcode the build did.
        // User/CI override always wins.
        DeveloperDirInjection.apply(to: &env, resolver: developerDir)

        return ExecPlan(cwd: wt, argv: argv, env: env, installedShimSymlinks: [])
    }

    // MARK: - simulator orchestration (M5)

    /// Lazy-clone or reuse the per-task simulator. Returns nil when:
    ///   • `noSim` is true (user explicitly opted out), or
    ///   • this `BuildService` was constructed without a
    ///     `SimulatorService` (unit tests, future host-only builds), or
    ///   • the task has no bound simulator and the user didn't pass
    ///     `--device`.
    /// The CLI is expected to forward both `resolved?.udid` and
    /// `resolved?.platform` into `prepareBuild` / `prepareTest`.
    public func resolveSimulator(
        task: TaskName,
        requestedDevice: String?,
        requestedRuntime: String? = nil,
        requestedPlatform: SimRuntimeVersion.Platform? = nil,
        noSim: Bool,
        shutdownTemplate: Bool = false
    ) throws -> SimulatorService.Resolved? {
        if noSim { return nil }
        guard let simulator else { return nil }
        return try simulator.ensureClone(
            task: task,
            requestedDevice: requestedDevice,
            requestedRuntime: requestedRuntime,
            requestedPlatform: requestedPlatform,
            shutdownTemplate: shutdownTemplate
        )
    }

    /// Best-effort scheme platform inference. The caller still runs
    /// xcodebuild normally if this returns nil; when it succeeds, Core
    /// can scope implicit simulator reuse to the scheme's platform.
    public func inferSimulatorPlatform(
        task: TaskName,
        scheme: String?,
        configuration: String?,
        xcodebuildContainer: XcodebuildContainer? = nil
    ) -> SimRuntimeVersion.Platform? {
        guard let scheme, !scheme.isEmpty, let settingsLister else {
            return nil
        }
        guard let data = try? settingsLister.showBuildSettings(
            cwd: workspace.worktreePath(for: task),
            xcodebuildContainer: xcodebuildContainer,
            scheme: scheme,
            configuration: configuration,
            destination: nil,
            derivedDataPath: nil
        ) else {
            return nil
        }
        return BuildSettingsParser.simulatorPlatform(in: data, targetMatching: scheme)
    }

    /// Platform hint used before simulator resolution. Avoids the
    /// expensive build-settings probe when the selected clone itself
    /// will tell us its platform (explicit `--device` with lazy clone),
    /// but still infers platform when it affects behavior:
    ///
    ///   • no `--device`: scope implicit binding reuse to the scheme;
    ///   • `--no-sim --device`: build a name-based destination for
    ///     the scheme's simulator platform.
    public func destinationPlatformHint(
        task: TaskName,
        scheme: String?,
        configuration: String?,
        requestedDevice: String?,
        requestedRuntime: String?,
        xcodebuildContainer: XcodebuildContainer? = nil,
        noSim: Bool
    ) -> SimRuntimeVersion.Platform? {
        if let runtime = requestedRuntime,
           let platform = SimRuntimeVersion.parse(runtimeLabel: runtime)?.platform {
            return platform
        }

        let hasDevice = !(requestedDevice ?? "").isEmpty
        let needsSchemeProbe = (!hasDevice && !noSim) || (hasDevice && noSim)
        guard needsSchemeProbe else { return nil }

        return inferSimulatorPlatform(
            task: task,
            scheme: scheme,
            configuration: configuration,
            xcodebuildContainer: xcodebuildContainer
        )
    }

    /// Run `simctl bootstatus -b` so xcodebuild can immediately pin its
    /// destination to the booted device. Idempotent.
    public func bootSimulator(_ resolved: SimulatorService.Resolved) throws {
        guard let simulator else { return }
        try simulator.bootIfNeeded(udid: resolved.udid, name: resolved.name)
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
                           scheme: String?, extraArgs: [String]? = nil) throws {
        try mutateState(task: task) { state in
            if let scheme { state.scheme = scheme }
            state.lastTest = TaskState.TestRecord(
                finishedAt: outcome.finishedAt,
                durationSeconds: outcome.durationSeconds,
                success: outcome.success,
                resultBundlePath: workspace.resultBundlePath(for: task),
                extraArgs: extraArgs
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
