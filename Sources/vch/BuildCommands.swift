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
        runtime: String?,
        noSim: Bool,
        verbose: Bool = false,
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
        let service = BuildService(
            workspace: workspace,
            simulator: simulator,
            developerDir: XcodeSelectDeveloperDirResolver()
        )

        // #6 reduced — single-scheme auto-pick. CLI flag wins, then
        // state.json's last-recorded scheme, then a single shared
        // scheme via `xcodebuild -list -json`. Anything else falls
        // through to xcodebuild's built-in default (today's behavior
        // when --scheme is omitted), so this is purely additive.
        let schemeResolver = SchemeResolver(
            workspace: workspace,
            lister: DiskXcodebuildLister()
        )
        let resolvedScheme = try schemeResolver.resolve(task: task, explicit: scheme)
        if let r = resolvedScheme, scheme == nil {
            switch r.source {
            case .explicit: break // unreachable: scheme == nil here
            case .persisted:
                CLIBridge.eprintln("→ using scheme '\(r.scheme)' (from .vch/state.json — pass --scheme to override)")
            case .autoDetected:
                CLIBridge.eprintln("→ using scheme '\(r.scheme)' (auto-detected single shared scheme)")
            }
        }

        let opts = BuildService.Options(
            scheme: resolvedScheme?.scheme ?? scheme,
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
            requestedRuntime: runtime,
            noSim: noSim
        )
        if let resolved {
            if resolved.createdNow {
                CLIBridge.eprintln("→ cloned simulator '\(resolved.name)' (\(resolved.udid.prefix(8))…\(formatRuntime(resolved.runtime)))")
            }
            CLIBridge.eprintln("→ booting simulator '\(resolved.name)'\(formatRuntime(resolved.runtime)) …")
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

        let result: PlanLauncher.RunResult
        switch action {
        case .build:
            // Build keeps today's firehose behavior — no parsing,
            // direct stdout/stderr inheritance.
            result = try PlanLauncher.run(plan)
        case .test:
            // Test goes through the tee path so we can summarize at
            // the end (#9). The full log is always preserved at
            // <wt>/.vch/last-test.log regardless of --verbose.
            let logURL = URL(fileURLWithPath: workspace.lastTestLogPath(for: task))
            CLIBridge.eprintln("→ running tests\(formatRuntime(resolved?.runtime)) — log: \(logURL.path)")
            let s = TestOutputSummarizer()
            result = try PlanLauncher.runTee(
                plan,
                logURL: logURL,
                mirror: verbose,
                onLine: { s.feed($0) }
            )
            // Render concise summary unconditionally — it's a useful
            // recap even in verbose mode (a 100-test firehose makes
            // the final ✓/✗ line easy to lose). Stdout (not stderr)
            // so `vch test foo | grep '✓'` works.
            let colorize = ANSI.defaultEnabledForStdout()
            print(s.render(colorize: colorize))
        }

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
            case .build: try service.recordBuild(task: task, outcome: outcome, scheme: opts.scheme)
            case .test:  try service.recordTest(task: task, outcome: outcome, scheme: opts.scheme)
            }
        } catch {
            CLIBridge.eprintln("warning: could not update state.json: \(error)")
        }

        throw ArgumentParser.ExitCode(result.exitCode)
    }

    /// `, runtime: iOS 18.5` or `` (when unknown). Formats inline so
    /// the build/test log line stays single-line.
    fileprivate static func formatRuntime(_ rt: SimRuntimeVersion?) -> String {
        guard let rt else { return "" }
        return ", runtime: iOS \(rt.major).\(rt.minor)"
    }
}

// MARK: - vch build

struct BuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Run `xcodebuild build` inside a task's worktree with isolation flags injected."
    )

    @Argument(help: "Task name to build.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long, help: "Scheme to build. If omitted, vch reuses the scheme persisted in .vch/state.json, or auto-picks the single shared scheme via `xcodebuild -list -json`.")
    var scheme: String?

    @Option(name: .long, help: "Build configuration (e.g. Debug, Release).")
    var configuration: String?

    @Option(name: .long, help: "Simulator device template (lazy-cloned per task on first use).")
    var device: String?

    @Option(name: .long, help: "Pin the simulator runtime (e.g. 'iOS 26.4' or the full SimRuntime identifier). Useful when multiple iOS runtimes share the same device name.")
    var runtime: String?

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
                runtime: runtime,
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

    @Argument(help: "Task name to test.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long, help: "Scheme to test. If omitted, vch reuses the scheme persisted in .vch/state.json, or auto-picks the single shared scheme via `xcodebuild -list -json`.")
    var scheme: String?

    @Option(name: .long, help: "Build configuration (e.g. Debug, Release).")
    var configuration: String?

    @Option(name: .long, help: "Simulator device template (lazy-cloned per task on first use).")
    var device: String?

    @Option(name: .long, help: "Pin the simulator runtime (e.g. 'iOS 26.4' or the full SimRuntime identifier). Useful when multiple iOS runtimes share the same device name.")
    var runtime: String?

    @Flag(name: .long, help: "Skip vch's lazy `simctl clone`; pass --device through as-is.")
    var noSim: Bool = false

    @Flag(name: .long, help: "Mirror xcodebuild's full output to the terminal in real time. Without this flag, vch prints only a concise summary at the end; the full log is always tee'd to <wt>/.vch/last-test.log (see `vch logs <name>`).")
    var verbose: Bool = false

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
                runtime: runtime,
                noSim: noSim,
                verbose: verbose,
                extraArgs: extraArgs
            )
        }
    }
}
