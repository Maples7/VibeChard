import ArgumentParser
import Foundation
import VibeChardCore

/// `vch run [<name>]` — build the task's app, then `simctl install`
/// + `simctl launch` it on the bound simulator clone. Closes #18.
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

    @Argument(help: "Task name to run. Optional inside a vch-managed task worktree.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String?

    @Option(name: .long, help: "Scheme to build/run. If omitted, vch reuses the scheme persisted in .vch/state.json, or auto-picks the single shared scheme via `xcodebuild -list -json`.")
    var scheme: String?

    @Option(name: .long, help: "Xcode project path to pass to xcodebuild (relative to the task worktree unless absolute). Cannot be combined with --workspace.")
    var project: String?

    @Option(name: .long, help: "Xcode workspace path to pass to xcodebuild (relative to the task worktree unless absolute). Cannot be combined with --project.")
    var workspace: String?

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

    @Option(name: .long, help: "Install + launch on an EXISTING shared simulator (by UDID or exact name) instead of a per-task clone. Skips `simctl clone`, records no per-task binding (so `vch land`/`vch rm` never reap it), and never erases it. Mutually exclusive with --device.")
    var existingSim: String?

    @Argument(parsing: .postTerminator,
              help: "Args forwarded verbatim to `simctl launch` (i.e. to the app's `main`).")
    var launchArgs: [String] = []

    func run() throws {
        try CLIBridge.run {
            try Self.execute(
                taskName: name,
                scheme: scheme,
                project: project,
                workspacePath: workspace,
                configuration: configuration,
                device: device,
                runtime: runtime,
                eraseClone: eraseClone,
                shutdownTemplate: shutdownTemplate,
                existingSim: existingSim,
                launchArgs: launchArgs
            )
        }
    }

    static func execute(
        taskName: String?,
        scheme: String?,
        project: String?,
        workspacePath: String?,
        configuration: String?,
        device: String?,
        runtime: String?,
        eraseClone: Bool = false,
        shutdownTemplate: Bool = false,
        existingSim: String? = nil,
        launchArgs: [String]
    ) throws {
        // #162: reject incompatible flag combinations up front so the
        // user is told immediately, regardless of cwd / workspace state.
        try ExistingSimulatorResolver.validateOptions(
            existingSim: existingSim,
            device: device,
            runtime: runtime,
            eraseClone: eraseClone,
            shutdownTemplate: shutdownTemplate
        )

        let cwd = FileManager.default.currentDirectoryPath
        let location = try WorkspaceLocator.locateCurrent(cwd: cwd)
        let workspace = location.workspace
        let task = try TaskArgumentResolver.resolve(
            explicit: taskName,
            current: location.taskName
        )
        let xcodebuildContainer = try XcodebuildContainer.resolve(
            project: project,
            workspace: workspacePath
        )
        let baseEnv = ProcessInfo.processInfo.environment

        let simctl = DiskSimctlClient()
        let simulator = SimulatorService(workspace: workspace, simctl: simctl)
        let buildService = BuildService(
            workspace: workspace,
            simulator: simulator,
            developerDir: XcodeSelectDeveloperDirResolver(),
            settingsLister: DiskBuildSettingsLister()
        )

        // Reuse the same scheme-resolution rules as `vch build`/`vch
        // test` so the three commands feel like one workflow.
        let schemeResolver = SchemeResolver(
            workspace: workspace,
            lister: DiskXcodebuildLister()
        )
        let resolvedScheme = try schemeResolver.resolve(
            task: task,
            explicit: scheme,
            xcodebuildContainer: xcodebuildContainer
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

        var opts = BuildService.Options(
            scheme: effectiveScheme,
            xcodebuildContainer: xcodebuildContainer,
            configuration: configuration,
            device: device,
            runtime: runtime,
            noSim: false,
            extraArgs: []
        )

        // Resolve the target simulator. Two paths:
        //   • #162 `--existing-sim`: install onto a pre-existing shared
        //     simulator (by UDID or name). No `simctl clone`, no
        //     per-task binding written to state.json, never erased.
        //   • default: lazy-clone (or reuse) a per-task simulator.
        // Both converge on `(simUDID, simPlatform, simName)`, then run
        // the same build → install → launch pipeline below.
        let simUDID: String
        let simPlatform: SimRuntimeVersion.Platform
        let simName: String

        if let existingSim {
            let match = try simulator.resolveExistingSimulator(selector: existingSim)
            guard let platform = match.runtime?.platform else {
                throw VibeChardError.simulatorPlatformUnknown(
                    udid: match.udid,
                    name: match.name
                )
            }
            simUDID = match.udid
            simPlatform = platform
            simName = match.name
            CLIBridge.eprintln(
                "→ targeting existing simulator '\(match.name)' (\(match.udid.prefix(8))…\(formatRuntime(match.runtime))) — shared, not a per-task clone"
            )
            CLIBridge.eprintln(
                "→ booting simulator '\(match.name)'\(formatRuntime(match.runtime)) …"
            )
            try simulator.bootIfNeeded(udid: match.udid, name: match.name)
        } else {
            opts.destinationPlatform = buildService.destinationPlatformHint(
                task: task,
                scheme: opts.scheme,
                configuration: configuration,
                requestedDevice: device,
                requestedRuntime: runtime,
                xcodebuildContainer: xcodebuildContainer,
                noSim: false
            )

            // `vch run` always needs a simulator clone to install onto.
            // `resolveSimulator` only returns nil when `noSim == true`
            // (which we forced false above) or when the workspace has no
            // simulator service, which never happens for the disk impl.
            // #164: `--shutdown-template` wins; otherwise the
            // `VCH_SHUTDOWN_TEMPLATE_ON_CLONE` opt-in makes it the default.
            guard let resolved = try buildService.resolveSimulator(
                task: task,
                requestedDevice: device,
                requestedRuntime: runtime,
                requestedPlatform: opts.destinationPlatform,
                noSim: false,
                shutdownTemplate: ShutdownTemplatePreference.resolve(
                    flag: shutdownTemplate, env: baseEnv
                )
            ) else {
                // Defensive: should be unreachable given DiskSimctlClient
                // is always wired in. Treat as a usage error so callers
                // can react appropriately.
                throw VibeChardError.missingArgument("--device")
            }
            guard let resolvedPlatform = resolved.platform else {
                throw VibeChardError.simulatorPlatformUnknown(
                    udid: resolved.udid,
                    name: resolved.name
                )
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

            simUDID = resolved.udid
            simPlatform = resolvedPlatform
            simName = resolved.name
        }

        // Best-effort: open Simulator.app so the user sees the run.
        // `simctl boot` only boots the headless simulator process.
        openSimulatorApp()

        let plan = try buildService.prepareBuild(
            task: task,
            options: opts,
            resolvedSimulatorUDID: simUDID,
            resolvedSimulatorPlatform: simPlatform,
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
            xcodebuildContainer: xcodebuildContainer,
            configuration: configuration,
            simulatorUDID: simUDID,
            simulatorPlatform: simPlatform
        )
        CLIBridge.eprintln(
            "→ installing '\(target.bundleID)' on \(simName) …"
        )
        try runService.installAndLaunch(
            target: target,
            simulatorUDID: simUDID,
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
        return ", runtime: \(rt.dottedLabel)"
    }
}
