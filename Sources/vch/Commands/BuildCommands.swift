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
        eraseClone: Bool = false,
        shutdownTemplate: Bool = false,
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
            developerDir: XcodeSelectDeveloperDirResolver(),
            settingsLister: DiskBuildSettingsLister()
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

        var opts = BuildService.Options(
            scheme: resolvedScheme?.scheme ?? scheme,
            configuration: configuration,
            device: device,
            runtime: runtime,
            noSim: noSim,
            extraArgs: extraArgs
        )
        opts.destinationPlatform = service.destinationPlatformHint(
            task: task,
            scheme: opts.scheme,
            configuration: configuration,
            requestedDevice: device,
            requestedRuntime: runtime,
            noSim: noSim
        )

        // M5: lazy-clone simulator if needed, then boot. We do this
        // BEFORE building the ExecPlan so the resolved UDID gets baked
        // into argv as `id=<UDID>`.
        let resolved = try service.resolveSimulator(
            task: task,
            requestedDevice: device,
            requestedRuntime: runtime,
            requestedPlatform: opts.destinationPlatform,
            noSim: noSim,
            shutdownTemplate: shutdownTemplate
        )
        let resolvedPlatform: SimRuntimeVersion.Platform?
        if let resolved {
            guard let platform = resolved.platform else {
                throw VibeChardError.simulatorPlatformUnknown(
                    udid: resolved.udid,
                    name: resolved.name
                )
            }
            resolvedPlatform = platform
        } else {
            resolvedPlatform = nil
        }
        if let resolved {
            if resolved.createdNow {
                CLIBridge.eprintln("→ cloned simulator '\(resolved.name)' (\(resolved.udid.prefix(8))…\(formatRuntime(resolved.runtime)))")
            }
            // #68: opt-in `--erase-clone` wipes accumulated state
            // (UserDefaults, app containers, keychain) before this
            // run. Useful when the template was used interactively
            // and a test depends on first-launch defaults. Costs
            // ~10–20s. Erase requires the clone to be shut down
            // first; `SimulatorService.eraseClone` chains
            // shutdown→erase, so this also collapses any prior
            // boot state.
            if eraseClone {
                CLIBridge.eprintln("→ erasing simulator '\(resolved.name)' (--erase-clone)")
                try simulator.eraseClone(udid: resolved.udid)
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
                resolvedSimulatorPlatform: resolvedPlatform,
                baseEnv: baseEnv
            )
        case .test:
            plan = try service.prepareTest(
                task: task, options: opts,
                resolvedSimulatorUDID: resolved?.udid,
                resolvedSimulatorPlatform: resolvedPlatform,
                baseEnv: baseEnv
            )
        }

        let result: PlanLauncher.RunResult
        let logURL: URL
        switch action {
        case .build:
            // #48: Build now mirrors the test path — concise summary
            // by default, full firehose only with --verbose. The full
            // log is always tee'd to <wt>/.vch/last-build.log so
            // `vch logs <name> --build` can recover it.
            logURL = URL(fileURLWithPath: workspace.lastBuildLogPath(for: task))
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
            logURL = URL(fileURLWithPath: workspace.lastTestLogPath(for: task))
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
                print(XcresultRenderer.render(
                    x,
                    colorize: colorize,
                    logPath: logURL.path,
                    resultBundlePath: bundlePath
                ))
            } else {
                print(s.render(
                    colorize: colorize,
                    logPath: logURL.path,
                    resultBundlePath: bundlePath
                ))
            }
        }

        if result.exitCode != 0, resolved != nil,
           let logText = try? String(contentsOf: logURL, encoding: .utf8) {
            let hintCommand: XcodebuildFailureHint.Command
            switch action {
            case .build: hintCommand = .build
            case .test: hintCommand = .test
            }
            if let hint = XcodebuildFailureHint.simulatorPreflightBusyHint(
                logText: logText,
                command: hintCommand,
                taskName: task.raw,
                device: device
            ) {
                CLIBridge.eprintln(hint)
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
        return ", runtime: \(rt.dottedLabel)"
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

    @Flag(name: .long, help: "Run `simctl shutdown && simctl erase` on the per-task clone before building. Wipes UserDefaults, app containers, and other state inherited from the template. Adds ~10–20s; off by default.")
    var eraseClone: Bool = false

    @Flag(name: .long, help: "If `simctl clone` fails because the warm template is currently Booted (e.g. you launched it from Simulator.app earlier), shut the template down and retry. Off by default: vch never auto-touches shared resources without an opt-in.")
    var shutdownTemplate: Bool = false

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
                eraseClone: eraseClone,
                shutdownTemplate: shutdownTemplate,
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
            For the common case — narrow a run to one suite or function —
            use the first-class `--only-testing` / `--skip-testing` flags
            (repeatable):

              # Run only one test class:
              vch test mytask --scheme MyScheme --device 'iPhone 16' \\
                --only-testing MyAppTests/MyClass

              # Run only one Swift Testing function:
              vch test mytask --scheme MyScheme --device 'iPhone 16' \\
                --only-testing 'MyAppTests/MyClass/myFunc()'

              # Skip a slow suite while running the rest:
              vch test mytask --scheme MyScheme --device 'iPhone 16' \\
                --skip-testing MyAppTests/SlowSuite

            For any other xcodebuild flag, pass it after a literal `--`
            using the single-dash xcodebuild form:

              vch test mytask --scheme MyScheme --device 'iPhone 16' \\
                -- -testPlan MyPlan -parallel-testing-enabled NO
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

    @Flag(name: .long, help: "Run `simctl shutdown && simctl erase` on the per-task clone before testing. Wipes UserDefaults, app containers, and other state inherited from the template — useful when a test depends on first-launch defaults but the template was used interactively. Adds ~10–20s; off by default.")
    var eraseClone: Bool = false

    @Flag(name: .long, help: "If `simctl clone` fails because the warm template is currently Booted (e.g. you launched it from Simulator.app earlier), shut the template down and retry. Off by default: vch never auto-touches shared resources without an opt-in.")
    var shutdownTemplate: Bool = false

    @Flag(name: .long, help: "Mirror xcodebuild's full output to the terminal in real time. Without this flag, vch prints only a concise summary at the end; the full log is always tee'd to <wt>/.vch/last-test.log (see `vch logs <name>`).")
    var verbose: Bool = false

    @Flag(name: .long, help: "Replay the last `vch test <name>` invocation verbatim, reusing the recorded extra args.")
    var rerun: Bool = false

    @Flag(name: .long, help: "Re-run only the tests that failed in the most recent `vch test <name>` (uses the recorded xcresult bundle).")
    var rerunFailed: Bool = false

    @Option(name: .long, parsing: .singleValue,
            help: "Narrow this run to one test identifier (`Target/Suite`, `Target/Suite/case()`, etc.). Translates to `xcodebuild -only-testing:<id>`; repeat the flag to combine selectors.")
    var onlyTesting: [String] = []

    @Option(name: .long, parsing: .singleValue,
            help: "Exclude one test identifier from this run (same shape as `--only-testing`). Translates to `xcodebuild -skip-testing:<id>`; repeatable.")
    var skipTesting: [String] = []

    @Argument(parsing: .postTerminator,
              help: "Extra args appended to xcodebuild after `--`.")
    var extraArgs: [String] = []

    func run() throws {
        try CLIBridge.run {
            // #46: --rerun / --rerun-failed are mutually exclusive
            // with each other and with positional extra args.
            //
            // #86: the new first-class --only-testing / --skip-testing
            // flags are also incompatible with --rerun*. The contract
            // for --rerun is "replay verbatim", and --rerun-failed
            // derives selectors from the recorded xcresult — letting
            // a stray --only-testing leak through would silently
            // override the failure-derived selection.
            if rerun && rerunFailed {
                throw VibeChardError.testConflictingRerunFlags
            }
            let hasFreshArgs = !extraArgs.isEmpty
                || !onlyTesting.isEmpty
                || !skipTesting.isEmpty
            if (rerun || rerunFailed) && hasFreshArgs {
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
                // #86: translate first-class selector flags into the
                // canonical `-only-testing:<id>` / `-skip-testing:<id>`
                // xcodebuild form, then append the user's verbatim
                // pass-through args.
                effectiveExtraArgs = TestSelectorMerger.extraArgs(
                    only: onlyTesting,
                    skip: skipTesting,
                    extra: extraArgs
                )
            }

            try BuildOrTest.execute(
                action: .test,
                taskName: name,
                scheme: scheme,
                configuration: configuration,
                device: device,
                runtime: runtime,
                noSim: noSim,
                eraseClone: eraseClone,
                shutdownTemplate: shutdownTemplate,
                verbose: verbose,
                extraArgs: effectiveExtraArgs
            )
        }
    }
}
