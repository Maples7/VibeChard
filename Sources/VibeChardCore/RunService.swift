import Foundation

/// #18 — `vch run <name>` orchestration.
///
/// The command sequences five phases, each of which is observable from
/// the CLI layer:
///
///   1. resolve scheme / simulator clone (delegated to
///      `SchemeResolver` + `BuildService.resolveSimulator`)
///   2. boot the clone (delegated to `BuildService.bootSimulator`)
///   3. build for the iOS Simulator destination
///      (`BuildService.prepareBuild` → `PlanLauncher.run`)
///   4. resolve the just-built `.app` bundle path + its
///      `PRODUCT_BUNDLE_IDENTIFIER` (`resolveTarget` below)
///   5. install + launch on the bound clone
///      (`installAndLaunch` below)
///
/// Steps 3 is run by the CLI (it owns `PlanLauncher`); steps 1, 2, 4,
/// and 5 are testable here against `FakeSimctl` /
/// `FakeBuildSettingsLister` without touching a real simulator.
public struct RunService: Sendable {
    public let workspace: Workspace
    public let simctl: SimctlClient
    public let settingsLister: BuildSettingsLister
    public let fs: FileSystem

    public init(
        workspace: Workspace,
        simctl: SimctlClient,
        settingsLister: BuildSettingsLister,
        fs: FileSystem = DiskFileSystem()
    ) {
        self.workspace = workspace
        self.simctl = simctl
        self.settingsLister = settingsLister
        self.fs = fs
    }

    /// What `resolveTarget(...)` hands back: the bundle id we'll pass
    /// to `simctl launch` plus the absolute path of the `.app` we'll
    /// pass to `simctl install`.
    public struct Target: Equatable, Sendable {
        public let bundleID: String
        public let appPath: String

        public init(bundleID: String, appPath: String) {
            self.bundleID = bundleID
            self.appPath = appPath
        }
    }

    /// Runs `xcodebuild -showBuildSettings -json` against the same
    /// scheme / configuration / destination the build used and pulls
    /// out `PRODUCT_BUNDLE_IDENTIFIER` and the resolved `.app` path.
    ///
    /// We intentionally call `-showBuildSettings` *after* the build
    /// rather than before: post-build it's a no-op metadata read,
    /// pre-build it might trigger an SPM resolve. Either way the
    /// settings are the same, but post-build is cheaper.
    public func resolveTarget(
        task: TaskName,
        scheme: String,
        configuration: String?,
        simulatorUDID: String
    ) throws -> Target {
        let cwd = workspace.worktreePath(for: task)
        let destination = "platform=iOS Simulator,id=\(simulatorUDID)"
        let derived = workspace.derivedDataDir(for: task)
        let json: Data
        do {
            json = try settingsLister.showBuildSettings(
                cwd: cwd,
                scheme: scheme,
                configuration: configuration,
                destination: destination,
                derivedDataPath: derived
            )
        } catch let err as VibeChardError {
            // Surface the underlying xcodebuild failure unchanged so
            // the user sees what went wrong, not a wrapper error.
            throw err
        }

        guard let bundleID = BuildSettingsParser.setting(
            "PRODUCT_BUNDLE_IDENTIFIER",
            in: json,
            targetMatching: scheme
        ), !bundleID.isEmpty else {
            throw VibeChardError.runBundleIDNotFound(scheme: scheme)
        }

        guard let settings = BuildSettingsParser.buildSettings(
            in: json,
            targetMatching: scheme
        ) else {
            // Unreachable: bundleID was found above, so buildSettings
            // exists. Defensive only.
            throw VibeChardError.runBundleIDNotFound(scheme: scheme)
        }

        // Prefer the post-build TARGET_BUILD_DIR (always points at the
        // active destination's products folder), then BUILT_PRODUCTS_DIR
        // as a fallback. Combine with WRAPPER_NAME / FULL_PRODUCT_NAME
        // — the wrapper wins for app extensions and widgets, but for
        // a plain app target the two are identical.
        let dir = settings["TARGET_BUILD_DIR"]
            ?? settings["BUILT_PRODUCTS_DIR"]
        let wrapper = settings["WRAPPER_NAME"]
            ?? settings["FULL_PRODUCT_NAME"]

        guard let dir, let wrapper, !dir.isEmpty, !wrapper.isEmpty else {
            throw VibeChardError.runAppBundleNotFound(
                path: "\(scheme).app (no TARGET_BUILD_DIR / WRAPPER_NAME)"
            )
        }

        let appPath = "\(dir)/\(wrapper)"
        guard fs.directoryExists(at: appPath) else {
            throw VibeChardError.runAppBundleNotFound(path: appPath)
        }

        return Target(bundleID: bundleID, appPath: appPath)
    }

    /// Install the resolved `.app` onto the clone, then launch it
    /// with `args` forwarded to `simctl launch`.
    public func installAndLaunch(
        target: Target,
        simulatorUDID: String,
        launchArgs: [String]
    ) throws {
        try simctl.install(udid: simulatorUDID, appPath: target.appPath)
        try simctl.launch(
            udid: simulatorUDID,
            bundleID: target.bundleID,
            args: launchArgs
        )
    }
}
