import ArgumentParser
import Foundation
import VibeChardCore

/// `vch run <name>` — build the task's app, then `simctl install` +
/// `simctl launch` it on the bound simulator clone. Closes #18.
///
/// This is essentially `vch build` followed by two simctl calls, so we
/// reuse `BuildOrTest`-style scheme/simulator resolution and the same
/// `BuildService.prepareBuild` → `PlanLauncher.run` pipeline. After a
/// successful build, `RunService.resolveTarget` shells out to
/// `xcodebuild -showBuildSettings -json` (cheap as a post-build read)
/// to extract `PRODUCT_BUNDLE_IDENTIFIER` and the `.app` bundle path,
/// then asks the same `SimctlClient` we already use for clone/boot to
/// install + launch.
///
/// Notes:
///
///   • A simulator is **required**: `--no-sim` would have nothing to
///     install onto, so we reject it.
///   • Everything after `--` is forwarded verbatim to `simctl launch`,
///     which forwards it to the app at launch (e.g.
///     `vch run alpha -- -UsePreviewSampleData`).
///   • `Simulator.app` is opened best-effort via `open -a Simulator`
///     so the user actually sees the launched app; failures here are
///     non-fatal (CI runs may not have a window server).
struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build, install, and launch a task's app on its bound simulator clone."
    )

    @Argument(help: "Task name to run.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long, help: "Scheme to build/run. If omitted, vch reuses the scheme persisted in .vch/state.json, or auto-picks the single shared scheme via `xcodebuild -list -json`.")
    var scheme: String?

    @Option(name: .long, help: "Build configuration (e.g. Debug, Release).")
    var configuration: String?

    @Option(name: .long, help: "Simulator device template (lazy-cloned per task on first use).")
    var device: String?

    @Option(name: .long, help: "Pin the simulator runtime (e.g. 'iOS 26.4', 'watchOS 11.5', 'visionOS 2.5', or the full SimRuntime identifier). Useful when multiple runtimes share the same device name.")
    var runtime: String?

    @Flag(name: .long, help: "Run `simctl shutdown && simctl erase` on the per-task clone before installing. Wipes UserDefaults, app containers, and other state inherited from the template. Adds ~10–20s; off by default.")
    var eraseClone: Bool = false

    @Flag(name: .long, help: "If `simctl clone` fails because the warm template is currently Booted (e.g. you launched it from Simulator.app earlier), shut the template down and retry. Off by default: vch never auto-touches shared resources without an opt-in.")
    var shutdownTemplate: Bool = false

    @Argument(parsing: .postTerminator,
              help: "Args forwarded verbatim to `simctl launch` (i.e. to the app's `main`).")
    var launchArgs: [String] = []

    func run() throws {
        try CLIBridge.run {
            try Self.execute(
                taskName: name,
                scheme: scheme,
                configuration: configuration,
                device: device,
                runtime: runtime,
                eraseClone: eraseClone,
                shutdownTemplate: shutdownTemplate,
                launchArgs: launchArgs
            )
        }
    }

    static func execute(
        taskName: String,
        scheme: String?,
        configuration: String?,
        device: String?,
        runtime: String?,
        eraseClone: Bool = false,
        shutdownTemplate: Bool = false,
        launchArgs: [String]
    ) throws {
        let task = try TaskName(taskName)
        let cwd = FileManager.default.currentDirectoryPath
        let workspace = try WorkspaceLocator.locate(cwd: cwd)
        let baseEnv = ProcessInfo.processInfo.environment

        let simctl = DiskSimctlClient()
        let simulator = SimulatorService(workspace: workspace, simctl: simctl)
        let buildService = BuildService(
            workspace: workspace,
            simulator: simulator,
            developerDir: XcodeSelectDeveloperDirResolver()
        )

        // Reuse the same scheme-resolution rules as `vch build`/`vch
        // test` so the three commands feel like one workflow.
        let schemeResolver = SchemeResolver(
            workspace: workspace,
            lister: DiskXcodebuildLister()
        )
        let resolvedScheme = try schemeResolver.resolve(
            task: task, explicit: scheme
        )
        if let r = resolvedScheme, scheme == nil {
            switch r.source {
            case .explicit: break
            case .persisted:
                CLIBridge.eprintln(
                    "→ using scheme '\(r.scheme)' (from .vch/state.json — pass --scheme to override)"
                )
            case .autoDetected:
                CLIBridge.eprintln(
                    "→ using scheme '\(r.scheme)' (auto-detected single shared scheme)"
                )
            }
        }
        let effectiveScheme = resolvedScheme?.scheme ?? scheme

        let opts = BuildService.Options(
            scheme: effectiveScheme,
            configuration: configuration,
            device: device,
            noSim: false,
            extraArgs: []
        )

        // `vch run` always needs a simulator clone to install onto.
        // `resolveSimulator` only returns nil when `noSim == true`
        // (which we forced false above) or when the workspace has no
        // simulator service, which never happens for the disk impl.
        guard let resolved = try buildService.resolveSimulator(
            task: task,
            requestedDevice: device,
            requestedRuntime: runtime,
            noSim: false,
            shutdownTemplate: shutdownTemplate
        ) else {
            // Defensive: should be unreachable given DiskSimctlClient
            // is always wired in. Treat as a usage error so callers
            // can react appropriately.
            throw VibeChardError.missingArgument("--device")
        }

        if resolved.createdNow {
            CLIBridge.eprintln(
                "→ cloned simulator '\(resolved.name)' (\(resolved.udid.prefix(8))…\(formatRuntime(resolved.runtime)))"
            )
        }
        // #68: opt-in `--erase-clone` wipes accumulated state
        // (UserDefaults, app containers, keychain) before this
        // run. Useful when the template was used interactively
        // and the app's first-launch behavior depends on a clean
        // defaults domain.
        if eraseClone {
            CLIBridge.eprintln(
                "→ erasing simulator '\(resolved.name)' (--erase-clone)"
            )
            try simulator.eraseClone(udid: resolved.udid)
        }
        CLIBridge.eprintln(
            "→ booting simulator '\(resolved.name)'\(formatRuntime(resolved.runtime)) …"
        )
        try buildService.bootSimulator(resolved)

        // Best-effort: open Simulator.app so the user sees the run.
        // `simctl boot` only boots the headless simulator process.
        openSimulatorApp()

        let plan = try buildService.prepareBuild(
            task: task,
            options: opts,
            resolvedSimulatorUDID: resolved.udid,
            baseEnv: baseEnv
        )

        let buildResult = try PlanLauncher.run(plan)
        let buildOutcome = BuildOutcome(
            success: buildResult.exitCode == 0,
            durationSeconds: buildResult.durationSeconds,
            finishedAt: Date()
        )
        do {
            try buildService.recordBuild(
                task: task, outcome: buildOutcome, scheme: opts.scheme
            )
        } catch {
            CLIBridge.eprintln(
                "warning: could not update state.json: \(error)"
            )
        }
        guard buildResult.exitCode == 0 else {
            // Surface xcodebuild's exit code unchanged.
            throw ArgumentParser.ExitCode(buildResult.exitCode)
        }

        guard let scheme = effectiveScheme else {
            // RunService needs a scheme to query showBuildSettings.
            // If we got here without one, xcodebuild built whatever
            // its default target was — we have no reliable way to
            // pick which target's bundle id to launch.
            throw VibeChardError.missingArgument("--scheme")
        }

        let runService = RunService(
            workspace: workspace,
            simctl: simctl,
            settingsLister: DiskBuildSettingsLister()
        )
        let target = try runService.resolveTarget(
            task: task,
            scheme: scheme,
            configuration: configuration,
            simulatorUDID: resolved.udid
        )
        CLIBridge.eprintln(
            "→ installing '\(target.bundleID)' on \(resolved.name) …"
        )
        try runService.installAndLaunch(
            target: target,
            simulatorUDID: resolved.udid,
            launchArgs: launchArgs
        )
        let argsSuffix = launchArgs.isEmpty
            ? ""
            : " (\(launchArgs.joined(separator: " ")))"
        CLIBridge.eprintln("✓ launched '\(target.bundleID)'\(argsSuffix)")
    }

    /// Bring up the Simulator.app window so the user sees the launched
    /// app. Best-effort — failures (CI, headless macOS, etc.) are
    /// silently ignored; the install/launch still happens against the
    /// already-booted simulator process.
    private static func openSimulatorApp() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-g", "-a", "Simulator"]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // ignore
        }
    }

    private static func formatRuntime(_ rt: SimRuntimeVersion?) -> String {
        guard let rt else { return "" }
        return ", runtime: iOS \(rt.major).\(rt.minor)"
    }
}
