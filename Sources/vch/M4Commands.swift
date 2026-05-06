import ArgumentParser
import Foundation
import VibeChardCore

/// Shared option set + run() body for `vch build` / `vch test`. Both
/// commands differ only in:
///   • the BuildService method they call (`prepareBuild` vs `prepareTest`)
///   • whether they request a `-resultBundlePath` (test does)
///   • how they record the outcome into state.json
private enum BuildOrTest {
    enum Action { case build, test }

    /// Run the action: build the plan, launch it, persist outcome,
    /// surface child's exit code.
    static func execute(
        action: Action,
        taskName: String,
        scheme: String?,
        configuration: String?,
        device: String?,
        noSim: Bool,
        extraArgs: [String]
    ) throws {
        let task = try TaskName(taskName)
        let cwd = FileManager.default.currentDirectoryPath
        let workspace = try WorkspaceLocator.locate(cwd: cwd)
        let baseEnv = ProcessInfo.processInfo.environment

        let simulator = SimulatorService(
            workspace: workspace,
            simctl: DiskSimctlClient()
        )
        let service = BuildService(workspace: workspace, simulator: simulator)
        let opts = BuildService.Options(
            scheme: scheme,
            configuration: configuration,
            device: device,
            noSim: noSim,
            extraArgs: extraArgs
        )

        // M5: lazy-clone simulator if needed, then boot. We do this
        // BEFORE building the ExecPlan so the resolved UDID gets baked
        // into argv as `id=<UDID>`.
        let resolved = try service.resolveSimulator(
            task: task,
            requestedDevice: device,
            noSim: noSim
        )
        if let resolved {
            if resolved.createdNow {
                CLIBridge.eprintln("→ cloned simulator '\(resolved.name)' (\(resolved.udid.prefix(8))…)")
            }
            CLIBridge.eprintln("→ booting simulator '\(resolved.name)' …")
            try service.bootSimulator(resolved)
        }

        let plan: ExecPlan
        switch action {
        case .build:
            plan = try service.prepareBuild(
                task: task, options: opts,
                resolvedSimulatorUDID: resolved?.udid,
                baseEnv: baseEnv
            )
        case .test:
            plan = try service.prepareTest(
                task: task, options: opts,
                resolvedSimulatorUDID: resolved?.udid,
                baseEnv: baseEnv
            )
        }

        let result = try PlanLauncher.run(plan)

        // Always write the outcome — the user wants to know about
        // failed runs too. We swallow only the inner write error so a
        // stale state.json doesn't mask the real (build) failure.
        let outcome = BuildOutcome(
            success: result.exitCode == 0,
            durationSeconds: result.durationSeconds,
            finishedAt: Date()
        )
        do {
            switch action {
            case .build: try service.recordBuild(task: task, outcome: outcome, scheme: scheme)
            case .test:  try service.recordTest(task: task, outcome: outcome, scheme: scheme)
            }
        } catch {
            CLIBridge.eprintln("warning: could not update state.json: \(error)")
        }

        throw ArgumentParser.ExitCode(result.exitCode)
    }
}

// MARK: - vch build

struct BuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Run `xcodebuild build` inside a task's worktree with isolation flags injected."
    )

    @Argument(help: "Task name to build.")
    var name: String

    @Option(name: .long, help: "Scheme to build. If omitted, xcodebuild's default applies.")
    var scheme: String?

    @Option(name: .long, help: "Build configuration (e.g. Debug, Release).")
    var configuration: String?

    @Option(name: .long, help: "Simulator device template (lazy-cloned per task on first use).")
    var device: String?

    @Flag(name: .long, help: "Skip vch's lazy `simctl clone`; pass --device through as-is.")
    var noSim: Bool = false

    @Argument(parsing: .postTerminator,
              help: "Extra args appended to xcodebuild after `--`.")
    var extraArgs: [String] = []

    func run() throws {
        try CLIBridge.run {
            try BuildOrTest.execute(
                action: .build,
                taskName: name,
                scheme: scheme,
                configuration: configuration,
                device: device,
                noSim: noSim,
                extraArgs: extraArgs
            )
        }
    }
}

// MARK: - vch test

struct TestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run `xcodebuild test` inside a task's worktree with -resultBundlePath set."
    )

    @Argument(help: "Task name to test.")
    var name: String

    @Option(name: .long, help: "Scheme to test.")
    var scheme: String?

    @Option(name: .long, help: "Build configuration (e.g. Debug, Release).")
    var configuration: String?

    @Option(name: .long, help: "Simulator device template (lazy-cloned per task on first use).")
    var device: String?

    @Flag(name: .long, help: "Skip vch's lazy `simctl clone`; pass --device through as-is.")
    var noSim: Bool = false

    @Argument(parsing: .postTerminator,
              help: "Extra args appended to xcodebuild after `--`.")
    var extraArgs: [String] = []

    func run() throws {
        try CLIBridge.run {
            try BuildOrTest.execute(
                action: .test,
                taskName: name,
                scheme: scheme,
                configuration: configuration,
                device: device,
                noSim: noSim,
                extraArgs: extraArgs
            )
        }
    }
}
