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
            // #48: Build now mirrors the test path — concise summary
            // by default, full firehose only with --verbose. The full
            // log is always tee'd to <wt>/.vch/last-build.log so
            // `vch logs <name> --build` can recover it.
            let logURL = URL(fileURLWithPath: workspace.lastBuildLogPath(for: task))
            CLIBridge.eprintln("→ building\(formatRuntime(resolved?.runtime)) — log: \(logURL.path)")
            let s = BuildOutputSummarizer()
            result = try PlanLauncher.runTee(
                plan,
                logURL: logURL,
                mirror: verbose,
                onLine: { s.feed($0) }
            )
            // Render concise summary unconditionally (the test branch
            // does the same — keeps the trailing ✓/✗ line easy to
            // grep even in verbose mode).
            let colorize = ANSI.defaultEnabledForStdout()
            print(s.render(durationSeconds: result.durationSeconds, colorize: colorize, logPath: logURL.path))
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
            //
            // #45: the streaming parser only recognizes XCTest
            // output. swift-testing targets emit a different
            // emoji-prefixed protocol that the parser ignores, which
            // would otherwise produce `✓ 0 passed in ?`. When the
            // streaming parser came back empty, fall through to
            // xcresult — the unified test-result format that covers
            // both frameworks.
            let colorize = ANSI.defaultEnabledForStdout()
            let bundlePath = workspace.resultBundlePath(for: task)
            let xcresult = try? DiskXcresultReader().summary(at: bundlePath)
            if (s.totalPassed + s.totalFailed) == 0,
               let x = xcresult,
               (x.totalPassed + x.totalFailed) > 0 {
                print(XcresultRenderer.render(x, colorize: colorize, logPath: logURL.path))
            } else {
                print(s.render(colorize: colorize, logPath: logURL.path))
            }
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
            case .test:  try service.recordTest(task: task, outcome: outcome,
                                                scheme: opts.scheme,
                                                extraArgs: extraArgs)
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

    @Option(name: .long, help: "Pin the simulator runtime (e.g. 'iOS 26.4', 'watchOS 11.5', 'visionOS 2.5', or the full SimRuntime identifier). Useful when multiple runtimes share the same device name.")
    var runtime: String?

    @Flag(name: .long, help: "Skip vch's lazy `simctl clone`; pass --device through as-is.")
    var noSim: Bool = false

    @Flag(name: .long, help: "Mirror xcodebuild's full output to the terminal in real time. Without this flag, vch prints only a concise summary at the end; the full log is always tee'd to <wt>/.vch/last-build.log (see `vch logs <name> --build`).")
    var verbose: Bool = false

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
                verbose: verbose,
                extraArgs: extraArgs
            )
        }
    }
}

// MARK: - vch test

struct TestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run `xcodebuild test` inside a task's worktree with -resultBundlePath set.",
        discussion: """
            Pass extra `xcodebuild` flags after a literal `--`. The two most
            common ones for narrowing a run:

              # Run only one test class:
              vch test mytask --scheme MyScheme --device 'iPhone 16' \\
                -- -only-testing 'MyAppTests/MyClass'

              # Run only one Swift Testing function:
              vch test mytask --scheme MyScheme --device 'iPhone 16' \\
                -- -only-testing 'MyAppTests/MyClass/myFunc()'

            Note: the flag is `-only-testing` (single dash) because that's
            the `xcodebuild` flag, and the `--` separator is required so
            ArgumentParser doesn't try to interpret it as a vch option.
            """
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

    @Option(name: .long, help: "Pin the simulator runtime (e.g. 'iOS 26.4', 'watchOS 11.5', 'visionOS 2.5', or the full SimRuntime identifier). Useful when multiple runtimes share the same device name.")
    var runtime: String?

    @Flag(name: .long, help: "Skip vch's lazy `simctl clone`; pass --device through as-is.")
    var noSim: Bool = false

    @Flag(name: .long, help: "Mirror xcodebuild's full output to the terminal in real time. Without this flag, vch prints only a concise summary at the end; the full log is always tee'd to <wt>/.vch/last-test.log (see `vch logs <name>`).")
    var verbose: Bool = false

    @Flag(name: .long, help: "Replay the last `vch test <name>` invocation verbatim, reusing the recorded extra args.")
    var rerun: Bool = false

    @Flag(name: .long, help: "Re-run only the tests that failed in the most recent `vch test <name>` (uses the recorded xcresult bundle).")
    var rerunFailed: Bool = false

    @Argument(parsing: .postTerminator,
              help: "Extra args appended to xcodebuild after `--`.")
    var extraArgs: [String] = []

    func run() throws {
        try CLIBridge.run {
            // #46: --rerun / --rerun-failed are mutually exclusive
            // with each other and with positional extra args.
            if rerun && rerunFailed {
                throw VibeChardError.testConflictingRerunFlags
            }
            if (rerun || rerunFailed) && !extraArgs.isEmpty {
                throw VibeChardError.testRerunWithExtraArgs
            }

            // Default path: extra args come straight from the CLI.
            // Rerun paths: load `state.json` + (for --rerun-failed)
            // the xcresult bundle to derive the effective args.
            let effectiveExtraArgs: [String]
            if rerun || rerunFailed {
                let task = try TaskName(name)
                let cwd = FileManager.default.currentDirectoryPath
                let workspace = try WorkspaceLocator.locate(cwd: cwd)
                let statePath = workspace.statePath(for: task)
                guard FileManager.default.fileExists(atPath: statePath),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
                      let state = try? TaskState.parse(data),
                      let last = state.lastTest else {
                    throw VibeChardError.testNoPriorRun(taskName: task.raw)
                }
                let priorArgs = last.extraArgs ?? []
                if rerunFailed {
                    let bundlePath = workspace.resultBundlePath(for: task)
                    let summary = (try? DiskXcresultReader().summary(at: bundlePath))
                    // #64: prefer `rerunIdentifier(targetName:)` over
                    // the raw `testIdentifier` so short-form
                    // identifiers (`Suite/Case()` instead of
                    // `Target/Suite/Case()`) get the test-target
                    // prefix prepended before they reach
                    // `xcodebuild -only-testing:`.
                    let ids = (summary?.failures ?? []).compactMap { $0.rerunIdentifier() }
                    if ids.isEmpty {
                        throw VibeChardError.testNoPriorFailures(taskName: task.raw)
                    }
                    effectiveExtraArgs = RerunPlanner.extraArgsForRerunFailed(
                        prior: priorArgs,
                        failureIdentifiers: ids
                    )
                    CLIBridge.eprintln("→ rerunning \(ids.count) failed test\(ids.count == 1 ? "" : "s") from last run")
                } else {
                    effectiveExtraArgs = priorArgs
                    CLIBridge.eprintln("→ rerunning last `vch test \(task.raw)` invocation\(priorArgs.isEmpty ? "" : " (with recorded args)")")
                }
            } else {
                effectiveExtraArgs = extraArgs
            }

            try BuildOrTest.execute(
                action: .test,
                taskName: name,
                scheme: scheme,
                configuration: configuration,
                device: device,
                runtime: runtime,
                noSim: noSim,
                verbose: verbose,
                extraArgs: effectiveExtraArgs
            )
        }
    }
}
