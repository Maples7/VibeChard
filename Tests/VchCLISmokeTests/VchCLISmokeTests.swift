// VchCLISmokeTests
//
// Closes the loop on the v0.5.0 / #82 class of bug, where the
// dispatcher's hardcoded reserved-name list drifted out of sync
// with `TaskName.reserved` and turned `vch prune` / `vch clean`
// into self-contradicting errors.
//
// We can't `@testable import vch` (executable target — Swift won't
// let us), and AGENTS.md hard rule #5 forbids extracting a third
// Sources/ target. Same Process-based pattern as ShimIntegrationTests:
// declare the vch executable as a SwiftPM dependency, locate it next
// to the test bundle, fork it under controlled args.

import Foundation
import Darwin
import XCTest
@testable import VibeChardCore

final class VchCLISmokeTests: XCTestCase {

    // MARK: - Locate the pre-built vch binary

    private static func vchPath() throws -> String {
        let testBundleURL = Bundle(for: VchCLISmokeTests.self).bundleURL
        let binDir = testBundleURL.deletingLastPathComponent()
        let candidate = binDir.appendingPathComponent("vch")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw NSError(domain: "VchCLISmokeTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "vch binary not found next to test bundle at \(candidate.path) — Package.swift dependency missing?"
            ])
        }
        return candidate.path
    }

    /// Names that appear in `vch --help` SUBCOMMANDS but should NOT
    /// be expected to show up in `TaskName.reserved` because they're
    /// ArgumentParser-injected (`help`) rather than user-registered.
    /// Empty for now — `help` is in `TaskName.reserved` anyway — but
    /// kept as a deliberate seam so future ArgumentParser surprises
    /// have an obvious place to land.
    private static let argumentParserBuiltins: Set<String> = []

    /// Aliases of registered subcommands. `vch list` registers itself
    /// as `list, ls` via ArgumentParser's `aliases`; both forms appear
    /// in `--help` output and both must be reserved (else the sugar
    /// dispatcher would catch only one). When adding a new alias here,
    /// also add it to `TaskName.reserved`.
    private static let aliasMap: [String: Set<String>] = [
        "list": ["ls"],
        "remove": ["rm"],
    ]

    // MARK: - Run vch under argv

    private struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private struct AdoptCurrentFixture {
        let rootDir: URL
        let repoPath: String
        let sidecarPath: String
        let gitEnv: [String: String]
    }

    private struct ManagedTaskFixture {
        let rootDir: URL
        let repoPath: String
        let taskPath: String
        let taskName: String
        let gitEnv: [String: String]
    }

    private func runVch(_ args: [String]) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try Self.vchPath())
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Empty env: vch doesn't need a TTY or HOME for `--help`. We
        // pass an explicit minimal env so the test stays hermetic.
        proc.environment = ["PATH": "/usr/bin:/bin"]
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(
            data: out.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: err.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return Result(
            exitCode: proc.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// Variant that lets the test caller set a working directory and
    /// extend the environment. Used by the `--adopt-current` smoke
    /// test, which has to invoke `vch new --adopt-current` from
    /// *inside* a linked git worktree and gives git enough env to
    /// avoid touching the developer's real `~/.gitconfig`.
    private func runVch(
        _ args: [String], cwd: String, env: [String: String]
    ) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try Self.vchPath())
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        var combined = env
        if combined["PATH"] == nil {
            combined["PATH"] = "/usr/bin:/bin"
        }
        proc.environment = combined
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(
            data: out.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: err.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return Result(
            exitCode: proc.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    // MARK: - Parse the SUBCOMMANDS section of `vch --help`

    /// Extract every command name (and its aliases) from the
    /// `SUBCOMMANDS:` section of `vch --help`. Each subcommand line
    /// looks like:
    ///     "  new                     Create a new isolated worktree..."
    ///     "  list, ls                List vch-managed worktrees."
    /// We split on commas to capture aliases as separate names.
    private func parseSubcommandNames(_ helpText: String) -> Set<String> {
        guard let range = helpText.range(of: "SUBCOMMANDS:\n") else {
            return []
        }
        let body = helpText[range.upperBound...]
        var names: Set<String> = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            // A blank line terminates the SUBCOMMANDS block; below it
            // sits the trailing "See 'vch help <subcommand>'..." note,
            // which we must not parse as a subcommand.
            if line.allSatisfy(\.isWhitespace) { break }
            // Subcommand lines start with exactly two spaces followed
            // by a non-space (description continuation lines start
            // with more leading whitespace).
            guard line.hasPrefix("  "),
                  !line.hasPrefix("   ") else { continue }
            let trimmed = line.drop(while: { $0 == " " })
            let firstWord = trimmed.split(separator: " ", maxSplits: 1).first
                .map(String.init) ?? ""
            for part in firstWord.split(separator: ",") {
                let name = String(part).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                names.insert(name)
            }
        }
        return names
    }

    // MARK: - Forward direction: reserved → subcommand dispatches

    /// Regression: in v0.5.0 (#82), `prune` and `clean` were in
    /// `TaskName.reserved` (rightly) but the sugar dispatcher had a
    /// drifted copy of the reserved list that omitted them, so
    /// `vch prune` reported `invalid task name`. This test would have
    /// failed before #83 and will fail again if any reserved name
    /// stops dispatching to a real subcommand.
    func testEveryReservedNameDispatchesToASubcommand() throws {
        // `help` is ArgumentParser's built-in, not a registered
        // subcommand. `vch help` shows root help (exit 0); `vch help
        // foo` shows foo's help. Skip from the per-name iteration.
        let names = TaskName.reserved.subtracting(["help"])
        for name in names {
            let result = try runVch([name, "--help"])
            XCTAssertEqual(
                result.exitCode, 0,
                """
                reserved name '\(name)' did NOT dispatch to a real subcommand.
                Either the subcommand was removed from VchCLI but not from
                TaskName.reserved, or the sugar dispatcher in
                TaskShortcutDispatcher is mis-routing it (the #82 class of
                bug).

                exit=\(result.exitCode)
                stderr: \(result.stderr)
                """
            )
        }
    }

    // MARK: - Reverse direction: registered → reserved

    /// Closes the OTHER half of the #82 loop: a subcommand registered
    /// in `VchCLI.configuration.subcommands` but not added to
    /// `TaskName.reserved` would silently let `vch <name>` short-
    /// circuit through the sugar dispatcher (because the dispatcher
    /// reads `TaskName.reserved`), creating the inverse error mode.
    /// Reading `vch --help`'s SUBCOMMANDS section keeps this test
    /// purely behavioural — we don't reach into VchCLI's internals.
    func testEveryRegisteredSubcommandIsReserved() throws {
        let help = try runVch(["--help"])
        XCTAssertEqual(help.exitCode, 0, "vch --help failed: \(help.stderr)")
        let parsed = parseSubcommandNames(help.stdout)
        XCTAssertFalse(
            parsed.isEmpty,
            "could not parse SUBCOMMANDS from `vch --help` output; the help format may have changed."
        )

        let expected = parsed.subtracting(Self.argumentParserBuiltins)
        let missing = expected.subtracting(TaskName.reserved)
        XCTAssertTrue(
            missing.isEmpty,
            """
            Subcommand(s) registered in vch but not in TaskName.reserved: \
            \(missing.sorted()).
            Add them to TaskName.reserved (Sources/VibeChardCore/Domain/TaskName.swift)
            so `vch <name>` dispatches to the subcommand instead of routing
            through the sugar path. This is the inverse of #82.
            """
        )
    }

    // MARK: - Alias consistency

    /// `list, ls` and `remove, rm` are documented aliases. Both forms
    /// appear in `vch --help` output and both must be reserved.
    func testDocumentedAliasesAreBothReserved() {
        for (canonical, aliases) in Self.aliasMap {
            XCTAssertTrue(
                TaskName.reserved.contains(canonical),
                "canonical name '\(canonical)' missing from TaskName.reserved"
            )
            for alias in aliases {
                XCTAssertTrue(
                    TaskName.reserved.contains(alias),
                    "alias '\(alias)' of '\(canonical)' missing from TaskName.reserved"
                )
            }
        }
    }

    // MARK: - #86: xcodebuild flag passthrough hint integration

    /// End-to-end check for the #86 hint wiring. The unit suite in
    /// `XcodebuildPassthroughHintTests` exercises the pure detector,
    /// but the *integration* — gated on ArgumentParser's
    /// `.validationFailure` exit code, emitted on stderr alongside
    /// ArgumentParser's own error+usage, in that order — only really
    /// lives in `VchCLI.main`. This smoke test forks the binary so
    /// any regression in the wiring (e.g. someone reaches for
    /// `exit(withError:)` and forgets to append the hint, or moves
    /// the print to stdout) gets caught.
    func testTestUnknownXcodebuildFlagPrintsHintOnStderr() throws {
        // `--testPlan` is a known xcodebuild flag with no first-class
        // vch equivalent, so the hint should point at the
        // pass-through form.
        let result = try runVch(["test", "any-task", "--testPlan", "MyPlan"])
        XCTAssertEqual(
            result.exitCode, 64,
            "expected ArgumentParser validationFailure (64), got \(result.exitCode); stderr: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("Unknown option '--testPlan'"),
            "expected ArgumentParser's own error on stderr; got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("hint:"),
            "expected the #86 hint line on stderr; got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("-- -testPlan"),
            "expected hint to suggest the pass-through form; got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stdout.isEmpty,
            "hint must go to stderr, not stdout; stdout: \(result.stdout)"
        )
    }

    /// Single-dash form of a first-class flag (`-only-testing`) should
    /// nudge the user toward the double-dash vch flag, NOT toward
    /// the pass-through dance.
    func testTestSingleDashFirstClassFlagPrintsFirstClassHint() throws {
        let result = try runVch(["test", "any-task", "-only-testing", "Foo/Bar"])
        XCTAssertEqual(
            result.exitCode, 64,
            "expected ArgumentParser validationFailure (64), got \(result.exitCode); stderr: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("hint:"),
            "expected the #86 hint line on stderr; got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("--only-testing"),
            "expected hint to suggest the first-class vch flag; got: \(result.stderr)"
        )
        XCTAssertFalse(
            result.stderr.contains("Pass it through after `--`"),
            "first-class hint must NOT suggest the pass-through; got: \(result.stderr)"
        )
    }

    /// Negative case: a valid `vch test` invocation that fails for a
    /// *different* reason (missing positional) must not get the hint.
    /// Guards against the gate (`hintForTestArgv`) becoming overly
    /// eager.
    func testTestMissingTaskNameDoesNotPrintHint() throws {
        let result = try runVch(["test"])
        XCTAssertNotEqual(result.exitCode, 0, "expected non-zero exit")
        XCTAssertFalse(
            result.stderr.contains("hint:"),
            "missing-argument error must not trigger the xcodebuild hint; got: \(result.stderr)"
        )
    }

    // MARK: - #89: generic unknown-option hint integration

    /// The motivating case from #89's body: the user invented
    /// `--extra` because they were reaching for a pass-through knob
    /// and didn't remember the `--` convention. Before #89, `vch
    /// test --extra` died with only the bare "Unknown option" line.
    /// After the fix, vch appends the actionable hint pointing at
    /// the `vch test … -- -extra <value>` form. End-to-end check
    /// since the unit suite can't see the AP error-message wiring.
    func testTestInventedFlagPrintsGenericPassthroughHint() throws {
        let result = try runVch(["test", "any-task", "--extra", "value"])
        XCTAssertEqual(
            result.exitCode, 64,
            "expected ArgumentParser validationFailure (64); stderr: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("Unknown option '--extra'"),
            "expected AP's own error on stderr; got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("hint:"),
            "expected the #89 generic hint line; got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("xcodebuild"),
            "expected hint to name xcodebuild for `vch test`; got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("-- -extra <value>"),
            "expected hint to show the canonical pass-through form; got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stdout.isEmpty,
            "hint must go to stderr, not stdout; stdout: \(result.stdout)"
        )
    }

    /// `vch build` shares the same xcodebuild downstream as `vch
    /// test`. An invented flag on it gets the same xcodebuild-themed
    /// hint — confirms #89's "any command with a `--` tail" claim
    /// for the build side.
    func testBuildInventedFlagPrintsGenericPassthroughHint() throws {
        let result = try runVch(["build", "any-task", "--extra", "value"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("Unknown option '--extra'"))
        XCTAssertTrue(result.stderr.contains("hint:"))
        XCTAssertTrue(result.stderr.contains("xcodebuild"))
        XCTAssertTrue(
            result.stderr.contains("vch build [<name>]"),
            "expected hint to name the user's actual subcommand; got: \(result.stderr)"
        )
    }

    /// `vch run`'s `-- <args>` tail is forwarded to `simctl launch`,
    /// not xcodebuild. Suggesting xcodebuild on a run-time error
    /// would actively mislead. Wording check: hint must mention the
    /// launched app and must NOT mention xcodebuild.
    func testRunInventedFlagPrintsAppLaunchHint() throws {
        let result = try runVch(["run", "any-task", "--extra", "value"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("Unknown option '--extra'"))
        XCTAssertTrue(result.stderr.contains("hint:"))
        XCTAssertTrue(
            result.stderr.contains("launched app"),
            "expected hint to mention the launched app; got: \(result.stderr)"
        )
        XCTAssertFalse(
            result.stderr.contains("xcodebuild"),
            "run hint must NOT mention xcodebuild; got: \(result.stderr)"
        )
    }

    /// #162: `--existing-sim` flag-conflict validation must be wired
    /// into the CLI, not just unit-tested in Core. The conflict is
    /// rejected *before* any workspace/simulator lookup, so this test
    /// is hermetic (no git repo, no simctl). Guards against the
    /// validation being dropped from `execute()` during a refactor.
    func testBuildRejectsExistingSimWithDevice() throws {
        let result = try runVch([
            "build", "--existing-sim", "iPhone 16", "--device", "iPhone 16 Pro",
        ])
        XCTAssertEqual(result.exitCode, ExitCode.usage, "stderr: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("mutually exclusive"),
            "expected the --device conflict message; got: \(result.stderr)"
        )
    }

    /// Same wiring guard for `vch run` + `--erase-clone`: erasing a
    /// shared simulator vch does not own is refused (hard rule #9).
    func testRunRejectsExistingSimWithEraseClone() throws {
        let result = try runVch([
            "run", "--existing-sim", "iPhone 16", "--erase-clone",
        ])
        XCTAssertEqual(result.exitCode, ExitCode.usage, "stderr: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("--erase-clone cannot be combined with --existing-sim"),
            "expected the --erase-clone conflict message; got: \(result.stderr)"
        )
    }

    /// AP's typo correction is a better diagnostic than our generic
    /// nudge. When `--schem` triggers a "Did you mean '--scheme'?"
    /// suggestion, we must defer to it rather than stacking a second
    /// contradictory hint underneath.
    func testTestTypoFallsThroughToArgumentParserSuggestion() throws {
        let result = try runVch(["test", "foo", "--schem", "MyApp"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(
            result.stderr.contains("Did you mean '--scheme'?"),
            "expected AP's typo suggestion; got: \(result.stderr)"
        )
        XCTAssertFalse(
            result.stderr.contains("hint:"),
            "our generic hint must defer to AP's typo suggestion; got: \(result.stderr)"
        )
    }

    /// Subcommands with no `-- <extra-args>` tail (e.g. `list`) must
    /// never get the hint — there's no pass-through plan for the
    /// user to be reaching for. Guards against the `downstream`
    /// lookup quietly broadening to every subcommand.
    func testListInventedFlagDoesNotPrintHint() throws {
        let result = try runVch(["list", "--bogus"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("Unknown option '--bogus'"))
        XCTAssertFalse(
            result.stderr.contains("hint:"),
            "commands without a `--` tail must not get the pass-through hint; got: \(result.stderr)"
        )
    }

    // MARK: - xcodebuild failure recovery hint integration

    func testTestPreflightBusyFailurePrintsRecoveryHintOnStderr() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
        let fixture = try makeManagedTaskFixture(
            taskName: "alpha",
            simulator: .init(
                cloneUDID: "SIM-1",
                sourceUDID: "SRC-1",
                name: "iPhone 16-vch-alpha",
                templateName: "iPhone 16",
                runtimeIdentifier: runtime
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }

        let devicesJSON = """
        {"devices":{"\(runtime)":[{"udid":"SIM-1","name":"iPhone 16-vch-alpha",\
        "state":"Booted","isAvailable":true}]}}
        """
        let toolEnv = try installFakeToolchain(
            rootDir: fixture.rootDir,
            devicesJSON: devicesJSON,
            xcodebuildStderr: """
            Failed to install or launch the test runner.
            Simulator device failed to launch com.maples7.BeanLedger.
            The request was denied by service delegate (SBMainWorkspace) for reason: Busy ("Application failed preflight checks").
            """,
            xcodebuildExitCode: 65
        )
        let env = fixture.gitEnv.merging(toolEnv) { _, new in new }

        let result = try runVch(
            ["test", "alpha", "--scheme", "App", "--device", "iPhone 16"],
            cwd: fixture.repoPath,
            env: env
        )

        XCTAssertEqual(result.exitCode, 65, "stderr: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("hint: xcodebuild reported SBMainWorkspace Busy"),
            "expected recovery hint on stderr; got: \(result.stderr)"
        )
        XCTAssertTrue(result.stderr.contains("vch test 'alpha' --erase-clone [same flags]"))
        XCTAssertTrue(result.stderr.contains("vch sim erase 'alpha' --device 'iPhone 16'"))
        XCTAssertFalse(
            result.stdout.contains("hint: xcodebuild reported SBMainWorkspace Busy"),
            "recovery hint must go to stderr, not stdout; stdout: \(result.stdout)"
        )
    }

    func testBuildInsideManagedTaskWorktreeCanOmitTaskName() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeManagedTaskFixture(
            taskName: "alpha",
            simulator: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }
        let toolEnv = try installFakeToolchain(
            rootDir: fixture.rootDir,
            devicesJSON: #"{"devices":{}}"#,
            xcodebuildStderr: "",
            xcodebuildExitCode: 0
        )
        let env = fixture.gitEnv.merging(toolEnv) { _, new in new }

        let result = try runVch(
            ["build", "--scheme", "App", "--no-sim"],
            cwd: fixture.taskPath,
            env: env
        )

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        let state = try TaskState.parse(Data(
            contentsOf: URL(fileURLWithPath: "\(fixture.taskPath)/.vch/state.json")
        ))
        XCTAssertEqual(state.name, "alpha")
        XCTAssertEqual(state.scheme, "App")
        XCTAssertEqual(state.lastBuild?.success, true)
    }

    func testTestInsideManagedTaskWorktreeCanOmitTaskName() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeManagedTaskFixture(
            taskName: "alpha",
            simulator: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }
        let toolEnv = try installFakeToolchain(
            rootDir: fixture.rootDir,
            devicesJSON: #"{"devices":{}}"#,
            xcodebuildStderr: "",
            xcodebuildExitCode: 0
        )
        let env = fixture.gitEnv.merging(toolEnv) { _, new in new }

        let result = try runVch(
            ["test", "--scheme", "App", "--no-sim"],
            cwd: fixture.taskPath,
            env: env
        )

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        let state = try TaskState.parse(Data(
            contentsOf: URL(fileURLWithPath: "\(fixture.taskPath)/.vch/state.json")
        ))
        XCTAssertEqual(state.name, "alpha")
        XCTAssertEqual(state.scheme, "App")
        XCTAssertEqual(state.lastTest?.success, true)
        XCTAssertEqual(state.lastTest?.extraArgs, [])
    }

    func testTestClassifiesIdleHangAfterTestingStarts() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeManagedTaskFixture(
            taskName: "alpha",
            simulator: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }
        let toolEnv = try installLongRunningXcodebuild(
            rootDir: fixture.rootDir,
            prelude: "Testing started"
        )
        let env = fixture.gitEnv.merging(toolEnv) { _, new in new }
        let terminatedPath = fixture.rootDir.appendingPathComponent("xcodebuild-terminated").path

        let result = try runVch(
            [
                "test", "alpha",
                "--scheme", "App",
                "--no-sim",
                "--test-execution-idle-timeout", "0.2",
            ],
            cwd: fixture.repoPath,
            env: env
        )

        XCTAssertEqual(result.exitCode, 124, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminatedPath), "xcodebuild was not terminated")
        XCTAssertTrue(result.stderr.contains("test execution did not complete"), result.stderr)
        XCTAssertTrue(result.stderr.contains("task: alpha"), result.stderr)
        XCTAssertTrue(result.stderr.contains("xcodebuild PID:"), result.stderr)
        XCTAssertTrue(result.stderr.contains("simulator: none resolved by vch"), result.stderr)
        XCTAssertTrue(result.stderr.contains("vch clean alpha --kill-stuck-tests"), result.stderr)
        XCTAssertTrue(result.stderr.contains("last-test.log"), result.stderr)
        XCTAssertTrue(result.stderr.contains("Result.xcresult"), result.stderr)
        XCTAssertTrue(result.stdout.contains("? test status unknown"), result.stdout)
    }

    func testTestEmitsProgressHeartbeatDuringSilentPhase() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeManagedTaskFixture(
            taskName: "alpha",
            simulator: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }
        // A short, output-quiet run that succeeds on its own: it emits
        // one line, then stays silent for ~0.8s before exiting 0. With a
        // 0.1s heartbeat the wrapper should print several "→ still
        // running" lines during that silent window — the #167 fix.
        let toolEnv = try installSlowSucceedingXcodebuild(
            rootDir: fixture.rootDir,
            silentSeconds: 0.8
        )
        let env = fixture.gitEnv.merging(toolEnv) { _, new in new }

        let result = try runVch(
            [
                "test", "alpha",
                "--scheme", "App",
                "--no-sim",
                "--progress-interval", "0.1",
                // Disable the idle watchdog so this exercises only the
                // heartbeat: the child exits cleanly on its own.
                "--test-execution-idle-timeout", "0",
            ],
            cwd: fixture.repoPath,
            env: env
        )

        XCTAssertEqual(result.exitCode, 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("→ still running ("),
            "expected a progress heartbeat on stderr\nstderr: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("last output"),
            "heartbeat should report time since last output\nstderr: \(result.stderr)"
        )
    }

    func testTestSuppressesProgressHeartbeatUnderVerbose() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeManagedTaskFixture(
            taskName: "alpha",
            simulator: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }
        let toolEnv = try installSlowSucceedingXcodebuild(
            rootDir: fixture.rootDir,
            silentSeconds: 0.8
        )
        let env = fixture.gitEnv.merging(toolEnv) { _, new in new }

        let result = try runVch(
            [
                "test", "alpha",
                "--scheme", "App",
                "--no-sim",
                "--verbose",
                "--progress-interval", "0.1",
                "--test-execution-idle-timeout", "0",
            ],
            cwd: fixture.repoPath,
            env: env
        )

        XCTAssertEqual(result.exitCode, 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        XCTAssertFalse(
            result.stderr.contains("→ still running ("),
            "heartbeat must be suppressed under --verbose\nstderr: \(result.stderr)"
        )
    }

    func testTestRejectsNegativeProgressInterval() throws {
        let result = try runVch(["test", "alpha", "--progress-interval=-1"])
        XCTAssertNotEqual(result.exitCode, 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("--progress-interval must be greater than or equal to 0"),
            "stderr: \(result.stderr)"
        )
    }

    func testTestTerminatesChildXcodebuildWhenWrapperGetsSIGTERM() throws {
        try assertTestTerminatesChildXcodebuildWhenWrapperGetsSignal(
            SIGTERM,
            expectedStatus: 143
        )
    }

    func testTestTerminatesChildXcodebuildWhenWrapperGetsSIGHUP() throws {
        try assertTestTerminatesChildXcodebuildWhenWrapperGetsSignal(
            SIGHUP,
            expectedStatus: 129
        )
    }

    private func assertTestTerminatesChildXcodebuildWhenWrapperGetsSignal(
        _ signalNumber: Int32,
        expectedStatus: Int32
    ) throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeManagedTaskFixture(
            taskName: "alpha",
            simulator: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }
        let toolEnv = try installLongRunningXcodebuild(rootDir: fixture.rootDir)
        let env = fixture.gitEnv.merging(toolEnv) { _, new in new }
        let readyPath = fixture.rootDir.appendingPathComponent("xcodebuild-ready").path
        let terminatedPath = fixture.rootDir.appendingPathComponent("xcodebuild-terminated").path
        let pidPath = fixture.rootDir.appendingPathComponent("xcodebuild.pid").path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try Self.vchPath())
        proc.arguments = ["test", "alpha", "--scheme", "App", "--no-sim"]
        proc.currentDirectoryURL = URL(fileURLWithPath: fixture.repoPath)
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        try proc.run()
        defer {
            if proc.isRunning {
                proc.terminate()
                waitUntilProcessExits(proc, timeout: 2)
            }
            if let childPID = readPID(at: pidPath), isProcessRunning(childPID) {
                _ = Darwin.kill(childPID, SIGTERM)
                Thread.sleep(forTimeInterval: 0.2)
                if isProcessRunning(childPID) {
                    _ = Darwin.kill(childPID, SIGKILL)
                }
            }
        }

        XCTAssertTrue(waitForFile(at: readyPath, timeout: 5), "xcodebuild did not start")
        _ = Darwin.kill(proc.processIdentifier, signalNumber)
        XCTAssertTrue(waitUntilProcessExits(proc, timeout: 5), "vch did not exit after signal \(signalNumber)")
        XCTAssertTrue(waitForFile(at: terminatedPath, timeout: 2), "xcodebuild did not receive signal \(signalNumber)")

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationReason, .exit, "stdout: \(stdout)\nstderr: \(stderr)")
        XCTAssertEqual(proc.terminationStatus, expectedStatus, "stdout: \(stdout)\nstderr: \(stderr)")
    }

    // MARK: - doctor JSON integration

    func testDoctorJSONReportsWorktreePruneAndStaleBindingHint() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeManagedTaskFixture(
            taskName: "alpha",
            simulator: .init(
                cloneUDID: "SIM-GONE",
                sourceUDID: "SRC-1",
                name: "iPhone 16-vch-alpha",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }
        let toolEnv = try installFakeToolchain(
            rootDir: fixture.rootDir,
            devicesJSON: #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[]}}"#,
            xcodebuildStderr: "",
            xcodebuildExitCode: 0
        )
        let env = fixture.gitEnv.merging(toolEnv) { _, new in new }

        let result = try runVch(
            ["doctor", "--json"],
            cwd: fixture.repoPath,
            env: env
        )

        XCTAssertEqual(result.exitCode, ExitCode.business, "stderr: \(result.stderr)")
        struct DoctorJSON: Decodable {
            struct StaleBinding: Decodable {
                let taskName: String
                let cloneUDID: String
                let cloneName: String
            }
            let worktreePruneRan: Bool
            let prunedStaleEntries: Bool
            let staleBindings: [StaleBinding]
            let staleBindingRepairHint: String?
        }
        let decoded = try JSONDecoder().decode(
            DoctorJSON.self,
            from: Data(result.stdout.utf8)
        )
        XCTAssertTrue(decoded.worktreePruneRan)
        XCTAssertFalse(decoded.prunedStaleEntries)
        XCTAssertEqual(decoded.staleBindings.count, 1)
        XCTAssertEqual(decoded.staleBindings[0].taskName, "alpha")
        XCTAssertEqual(decoded.staleBindings[0].cloneUDID, "SIM-GONE")
        XCTAssertEqual(decoded.staleBindings[0].cloneName, "iPhone 16-vch-alpha")
        XCTAssertTrue(
            decoded.staleBindingRepairHint?.contains("vch sim clone <task> --device") ?? false
        )
    }

    // MARK: - Agent runbook discovery

    func testRunbookPrintsVersionPinnedReference() throws {
        let result = try runVch(["runbook"])

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("vch      \(VibeChard.version)"))
        XCTAssertTrue(result.stdout.contains(VibeChard.agentRunbookURL))
        XCTAssertTrue(result.stdout.contains(VibeChard.homebrewAgentRunbookPath))
        XCTAssertTrue(result.stderr.isEmpty, "stderr: \(result.stderr)")
    }

    func testRunbookJSONPrintsVersionPinnedReference() throws {
        struct RunbookJSON: Decodable {
            let vch: String
            let url: String
            let local: String?
            let homebrew: String
        }

        let result = try runVch(["runbook", "--json"])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("\"local\""))

        let decoded = try JSONDecoder().decode(
            RunbookJSON.self,
            from: Data(result.stdout.utf8)
        )
        XCTAssertEqual(decoded.vch, VibeChard.version)
        XCTAssertEqual(decoded.url, VibeChard.agentRunbookURL)
        XCTAssertEqual(decoded.homebrew, VibeChard.homebrewAgentRunbookPath)
        XCTAssertNil(decoded.local)
    }

    // MARK: - #98 follow-up: --adopt-current end-to-end

    func testNewWithoutNameRequiresNameUnlessAdoptingCurrent() throws {
        let result = try runVch(["new"])

        XCTAssertEqual(result.exitCode, ExitCode.usage)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            result.stderr.contains("missing argument: task name"),
            "stderr should explain the missing task name, got: \(result.stderr)"
        )
    }

    /// End-to-end smoke test for `vch new --adopt-current` and its
    /// downstream consumers. This is the user-visible side of PR #98:
    /// for a git worktree the user created themselves (e.g. via a
    /// codex / claude session script), `vch new --adopt-current` must
    /// infer the task name from the linked worktree directory, register
    /// the worktree without trying to clone it, and every subsequent vch
    /// command must operate on the externally-created path rather than
    /// the conventional `<repo>-<task>`.
    ///
    /// Each unit test in this PR pins a single seam (BuildService,
    /// SyncService, etc.) but the chain is wide; if any link bypasses
    /// `Workspace.taskWorktreePaths`, this test fails with a concrete
    /// path mismatch rather than a unit-level abstraction error.
    ///
    /// Coverage targets (one assertion per intent):
    /// 1.  `vch new --adopt-current` succeeds without `simctl` or
    ///     `xcodebuild` and prints the adopted path on stdout.
    /// 2.  `vch path` resolves to the adopted path, not
    ///     `<repo>-<task>`.
    /// 3.  `vch state --field worktreeOwnership` reports `adopted`.
    /// 4.  `vch list --json` reports the adopted path AND the user's
    ///     branch (`feature/codex`, not the synthetic `agent/<task>`).
    /// 5.  `vch rm` unregisters the task with explicit output,
    ///     deletes only vch-owned scratch under the adopted worktree,
    ///     and leaves the worktree itself and the user's branch
    ///     untouched.
    func testAdoptCurrentEndToEnd() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeAdoptCurrentFixture(
            worktreeLeaf: "codex-session",
            branch: "feature/codex"
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.rootDir)
        }
        let repoPath = fixture.repoPath
        let sidecarPath = fixture.sidecarPath
        let gitEnv = fixture.gitEnv
        // The user has their own naming convention; vch must preserve
        // the branch the fixture created, not synthesise agent/<task>.

        // ---------- 1. vch new --adopt-current ----------
        let newResult = try runVch(
            ["new", "--adopt-current"],
            cwd: sidecarPath, env: gitEnv
        )
        XCTAssertEqual(
            newResult.exitCode, 0,
            "vch new --adopt-current failed.\nstdout: \(newResult.stdout)\nstderr: \(newResult.stderr)"
        )
        XCTAssertEqual(
            newResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            try sidecarPath.resolvingSymlinks(),
            "vch new --adopt-current must print the adopted worktree path"
        )

        // ---------- 2. vch path codex-session ----------
        let pathResult = try runVch(
            ["path", "codex-session"], cwd: sidecarPath, env: gitEnv
        )
        XCTAssertEqual(pathResult.exitCode, 0, "stderr: \(pathResult.stderr)")
        XCTAssertEqual(
            pathResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            try sidecarPath.resolvingSymlinks(),
            "`vch path` must resolve through the adopted-worktree override, not `<repo>-<task>`"
        )

        // ---------- 3. vch state --field worktreeOwnership ----------
        let stateResult = try runVch(
            ["state", "codex-session", "--field", "worktreeOwnership"],
            cwd: sidecarPath, env: gitEnv
        )
        XCTAssertEqual(stateResult.exitCode, 0, "stderr: \(stateResult.stderr)")
        XCTAssertEqual(
            stateResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "adopted",
            "worktreeOwnership must persist as 'adopted'"
        )

        // ---------- 4. vch list --json ----------
        let listResult = try runVch(
            ["list", "--json"], cwd: sidecarPath, env: gitEnv
        )
        XCTAssertEqual(listResult.exitCode, 0, "stderr: \(listResult.stderr)")
        // Parse rather than substring-match: substring-matching path
        // strings would silently pass if `<repo>-codex-session` also
        // happened to contain "codex-session".
        let listData = Data(listResult.stdout.utf8)
        let listJSON = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
        let entry = try XCTUnwrap(
            listJSON?.first(where: { ($0["name"] as? String) == "codex-session" }),
            "vch list --json did not include the adopted task. raw: \(listResult.stdout)"
        )
        XCTAssertEqual(
            entry["path"] as? String, try sidecarPath.resolvingSymlinks(),
            "list path must be the adopted path, not <repo>-<task>"
        )
        XCTAssertEqual(
            entry["branch"] as? String, "feature/codex",
            "list branch must be the user's branch, not the synthetic agent/<task>"
        )

        // ---------- 5. vch rm codex-session ----------
        let rmResult = try runVch(
            ["rm", "codex-session"], cwd: sidecarPath, env: gitEnv
        )
        XCTAssertEqual(rmResult.exitCode, 0, "stderr: \(rmResult.stderr)")
        XCTAssertTrue(
            rmResult.stdout.contains("unregistered codex-session"),
            "adopted remove should say it unregistered the task, got: \(rmResult.stdout)"
        )
        XCTAssertTrue(
            rmResult.stdout.contains("kept external worktree"),
            "adopted remove should explain that the external worktree remains, got: \(rmResult.stdout)"
        )
        XCTAssertTrue(
            rmResult.stdout.contains("feature/codex"),
            "adopted remove should mention the preserved branch, got: \(rmResult.stdout)"
        )

        let listAfterRemoveResult = try runVch(
            ["list", "--json"], cwd: sidecarPath, env: gitEnv
        )
        XCTAssertEqual(listAfterRemoveResult.exitCode, 0, "stderr: \(listAfterRemoveResult.stderr)")
        let listAfterRemoveData = Data(listAfterRemoveResult.stdout.utf8)
        let listAfterRemoveJSON = try JSONSerialization.jsonObject(with: listAfterRemoveData) as? [[String: Any]]
        XCTAssertEqual(
            listAfterRemoveJSON?.count, 0,
            "unregistered adopted task should disappear from vch list. raw: \(listAfterRemoveResult.stdout)"
        )

        // ---------- 6. Adopted worktree + branch survive ----------
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarPath, isDirectory: &isDir),
            "adopted worktree directory must survive `vch rm`; vch only owned `.vch` / `.agent-build` inside it"
        )
        XCTAssertTrue(isDir.boolValue, "\(sidecarPath) should still be a directory")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(sidecarPath)/.vch"),
            "`.vch/` scratch dir must have been scrubbed by `vch rm`"
        )
        // The user's branch must still exist in the main repo; this
        // is the load-bearing contract of adopt-current — vch never
        // touches state it doesn't own.
        let branchProbe = try captureGit(
            ["rev-parse", "--verify", "feature/codex"],
            cwd: repoPath, env: gitEnv
        )
        XCTAssertEqual(
            branchProbe.exitCode, 0,
            "feature/codex must still exist after `vch rm`. stderr: \(branchProbe.stderr)"
        )
    }

    func testAdoptCurrentWithExplicitNameUsesExplicitName() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeAdoptCurrentFixture(
            worktreeLeaf: "external-session",
            branch: "feature/explicit"
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.rootDir)
        }

        let invalidResult = try runVch(
            ["new", " explicit-task", "--adopt-current"],
            cwd: fixture.sidecarPath, env: fixture.gitEnv
        )
        XCTAssertEqual(invalidResult.exitCode, ExitCode.usage)
        XCTAssertTrue(
            invalidResult.stderr.contains("invalid task name ' explicit-task'"),
            "explicit names must not be trimmed or treated as omitted; stderr: \(invalidResult.stderr)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(fixture.sidecarPath)/.vch/state.json"),
            "invalid explicit task name must fail before adopting the worktree"
        )

        let newResult = try runVch(
            ["new", "explicit-task", "--adopt-current"],
            cwd: fixture.sidecarPath, env: fixture.gitEnv
        )
        XCTAssertEqual(
            newResult.exitCode, 0,
            "vch new explicit-task --adopt-current failed.\nstdout: \(newResult.stdout)\nstderr: \(newResult.stderr)"
        )
        XCTAssertEqual(
            newResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            try fixture.sidecarPath.resolvingSymlinks()
        )

        let pathResult = try runVch(
            ["path", "explicit-task"],
            cwd: fixture.sidecarPath, env: fixture.gitEnv
        )
        XCTAssertEqual(pathResult.exitCode, 0, "stderr: \(pathResult.stderr)")
        XCTAssertEqual(
            pathResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            try fixture.sidecarPath.resolvingSymlinks()
        )

        let stateNameResult = try runVch(
            ["state", "explicit-task", "--field", "name"],
            cwd: fixture.sidecarPath, env: fixture.gitEnv
        )
        XCTAssertEqual(stateNameResult.exitCode, 0, "stderr: \(stateNameResult.stderr)")
        XCTAssertEqual(
            stateNameResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "explicit-task"
        )
    }

    func testListGitStatusMarksMergedDirtyWorktreeAsDirty() throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available"
        )

        let fixture = try makeManagedTaskFixture(
            taskName: "dirty-merged",
            simulator: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootDir) }
        try "uncommitted\n".write(
            toFile: "\(fixture.taskPath)/uncommitted.txt",
            atomically: true,
            encoding: .utf8
        )

        let result = try runVch(
            ["list", "--git-status"],
            cwd: fixture.repoPath,
            env: fixture.gitEnv
        )

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        let row = try XCTUnwrap(
            result.stdout.split(separator: "\n").first { $0.contains("dirty-merged") },
            "expected dirty task row in list output: \(result.stdout)"
        )
        let columns = row.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        XCTAssertGreaterThanOrEqual(columns.count, 8, "could not parse list row: \(row)")
        XCTAssertEqual(columns[6], "yes", "DIRTY column should report the worktree change")
        XCTAssertEqual(columns[7], "dirty", "MERGED column must not say yes for dirty worktrees")
    }

    // MARK: - smoke-test git helpers

    private func makeManagedTaskFixture(
        taskName: String,
        simulator: TaskState.SimulatorRecord?
    ) throws -> ManagedTaskFixture {
        let rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vch-managed-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: rootDir, withIntermediateDirectories: true
        )
        var keepRootDir = false
        defer {
            if !keepRootDir {
                try? FileManager.default.removeItem(at: rootDir)
            }
        }

        let repoPath = rootDir.appendingPathComponent("Repo").path
        let taskPath = rootDir.appendingPathComponent("Repo-\(taskName)").path
        try FileManager.default.createDirectory(
            atPath: repoPath, withIntermediateDirectories: true
        )
        let gitEnv = hermeticGitEnv(rootDir: rootDir)
        try runGit(["init", "-q", "-b", "main"], cwd: repoPath, env: gitEnv)
        try runGit(["config", "commit.gpgsign", "false"], cwd: repoPath, env: gitEnv)
        try "hello\n".write(
            toFile: "\(repoPath)/README.md",
            atomically: true, encoding: .utf8
        )
        try runGit(["add", "README.md"], cwd: repoPath, env: gitEnv)
        try runGit(["commit", "-q", "-m", "initial"], cwd: repoPath, env: gitEnv)
        try runGit(
            ["worktree", "add", "-b", "agent/\(taskName)", taskPath],
            cwd: repoPath, env: gitEnv
        )

        try FileManager.default.createDirectory(
            atPath: "\(taskPath)/.vch",
            withIntermediateDirectories: true
        )
        var state = TaskState(
            name: taskName,
            branch: "agent/\(taskName)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbee",
            baseBranch: "main"
        )
        if let simulator {
            state.setSimulators([simulator])
        }
        try state.jsonData().write(
            to: URL(fileURLWithPath: "\(taskPath)/.vch/state.json")
        )

        keepRootDir = true
        return ManagedTaskFixture(
            rootDir: rootDir,
            repoPath: repoPath,
            taskPath: taskPath,
            taskName: taskName,
            gitEnv: gitEnv
        )
    }

    private func installFakeToolchain(
        rootDir: URL,
        devicesJSON: String,
        xcodebuildStderr: String,
        xcodebuildExitCode: Int32
    ) throws -> [String: String] {
        let fakeRoot = rootDir.appendingPathComponent("FakeXcode")
        let developerDir = fakeRoot.appendingPathComponent("Contents/Developer")
        let developerBin = developerDir.appendingPathComponent("usr/bin")
        let pathBin = rootDir.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(
            at: developerBin,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: pathBin,
            withIntermediateDirectories: true
        )

        let devicesPath = rootDir.appendingPathComponent("simctl-devices.json")
        try devicesJSON.write(to: devicesPath, atomically: true, encoding: .utf8)

        try writeExecutable(
            developerBin.appendingPathComponent("xcrun"),
            body: """
            #!/bin/sh
            tool="$1"
            shift
                        if [ "$tool" = "git" ]; then
                            unset DEVELOPER_DIR
                            exec /usr/bin/git "$@"
                        fi
            exec "$DEVELOPER_DIR/usr/bin/$tool" "$@"
            """
        )
        try writeExecutable(
            developerBin.appendingPathComponent("simctl"),
            body: """
            #!/bin/sh
            if [ "$1" = "list" ] && [ "$2" = "devices" ]; then
              cat "$VCH_SMOKE_SIMCTL_DEVICES_JSON"
              exit 0
            fi
            if [ "$1" = "bootstatus" ] || [ "$1" = "shutdown" ] || [ "$1" = "erase" ] || [ "$1" = "delete" ]; then
              exit 0
            fi
            echo "unexpected simctl invocation: $*" >&2
            exit 1
            """
        )
        let xcodebuildBody = """
        #!/bin/sh
        cat <<'EOF' >&2
        \(xcodebuildStderr)
        EOF
        exit \(xcodebuildExitCode)
        """
        try writeExecutable(
            developerBin.appendingPathComponent("xcodebuild"),
            body: xcodebuildBody
        )
        try writeExecutable(
            pathBin.appendingPathComponent("xcodebuild"),
            body: xcodebuildBody
        )

        return [
            "DEVELOPER_DIR": developerDir.path,
            "PATH": "\(pathBin.path):/usr/bin:/bin",
            "VCH_SMOKE_SIMCTL_DEVICES_JSON": devicesPath.path,
        ]
    }

    private func installLongRunningXcodebuild(rootDir: URL, prelude: String = "") throws -> [String: String] {
        let pathBin = rootDir.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(
            at: pathBin,
            withIntermediateDirectories: true
        )
        let preludeBlock: String
        if prelude.isEmpty {
            preludeBlock = ""
        } else {
            preludeBlock = """
            cat <<'EOF'
            \(prelude)
            EOF
            """
        }
        try writeExecutable(
            pathBin.appendingPathComponent("xcodebuild"),
            body: """
            #!/bin/sh
            echo $$ > "$VCH_SMOKE_XCODEBUILD_PID"
            trap 'touch "$VCH_SMOKE_XCODEBUILD_TERMINATED"; exit 129' HUP
            trap 'touch "$VCH_SMOKE_XCODEBUILD_TERMINATED"; exit 143' TERM
            trap 'touch "$VCH_SMOKE_XCODEBUILD_TERMINATED"; exit 130' INT
            \(preludeBlock)
            touch "$VCH_SMOKE_XCODEBUILD_READY"
            while :; do
              sleep 1
            done
            """
        )
        return [
            "PATH": "\(pathBin.path):/usr/bin:/bin",
            "VCH_SMOKE_XCODEBUILD_PID": rootDir.appendingPathComponent("xcodebuild.pid").path,
            "VCH_SMOKE_XCODEBUILD_READY": rootDir.appendingPathComponent("xcodebuild-ready").path,
            "VCH_SMOKE_XCODEBUILD_TERMINATED": rootDir.appendingPathComponent("xcodebuild-terminated").path,
        ]
    }

    private func installSlowSucceedingXcodebuild(rootDir: URL, silentSeconds: Double) throws -> [String: String] {
        let pathBin = rootDir.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(
            at: pathBin,
            withIntermediateDirectories: true
        )
        // Emit one line, fall silent for `silentSeconds`, then exit 0.
        // The silent window is what the heartbeat must illuminate, and
        // the self-terminating child keeps the test from depending on
        // the idle-timeout watchdog to end the run.
        try writeExecutable(
            pathBin.appendingPathComponent("xcodebuild"),
            body: """
            #!/bin/sh
            echo "Testing started"
            sleep \(silentSeconds)
            exit 0
            """
        )
        return [
            "PATH": "\(pathBin.path):/usr/bin:/bin",
        ]
    }

    private func writeExecutable(_ url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }

    private func hermeticGitEnv(rootDir: URL) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "HOME": rootDir.path,
            "XDG_CONFIG_HOME": rootDir.appendingPathComponent("xdg").path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "vch test",
            "GIT_AUTHOR_EMAIL": "vch@test.local",
            "GIT_COMMITTER_NAME": "vch test",
            "GIT_COMMITTER_EMAIL": "vch@test.local",
        ]
    }

    private func waitForFile(at path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    @discardableResult
    private func waitUntilProcessExits(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    private func readPID(at path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isProcessRunning(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func makeAdoptCurrentFixture(
        worktreeLeaf: String,
        branch: String
    ) throws -> AdoptCurrentFixture {
        let rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vch-adopt-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: rootDir, withIntermediateDirectories: true
        )
        var keepRootDir = false
        defer {
            if !keepRootDir {
                try? FileManager.default.removeItem(at: rootDir)
            }
        }
        let repoPath = rootDir.appendingPathComponent("Repo").path
        let sidecarPath = rootDir.appendingPathComponent(worktreeLeaf).path
        try FileManager.default.createDirectory(
            atPath: repoPath, withIntermediateDirectories: true
        )

        // Stay strictly inside `rootDir`: HOME, XDG_CONFIG_HOME, and
        // GIT_CONFIG_NOSYSTEM together keep the test from picking up
        // the developer's real git config (signing, hooks, …).
        let gitEnv = hermeticGitEnv(rootDir: rootDir)
        try runGit(["init", "-q", "-b", "main"], cwd: repoPath, env: gitEnv)
        try runGit(["config", "commit.gpgsign", "false"], cwd: repoPath, env: gitEnv)
        try "hello\n".write(
            toFile: "\(repoPath)/README.md",
            atomically: true, encoding: .utf8
        )
        try runGit(["add", "README.md"], cwd: repoPath, env: gitEnv)
        try runGit(["commit", "-q", "-m", "initial"], cwd: repoPath, env: gitEnv)
        try runGit(
            ["worktree", "add", "-b", branch, sidecarPath],
            cwd: repoPath, env: gitEnv
        )

        keepRootDir = true
        return AdoptCurrentFixture(
            rootDir: rootDir,
            repoPath: repoPath,
            sidecarPath: sidecarPath,
            gitEnv: gitEnv
        )
    }

    private func runGit(
        _ args: [String], cwd: String, env: [String: String]
    ) throws {
        let result = try captureGit(args, cwd: cwd, env: env)
        guard result.exitCode == 0 else {
            XCTFail(
                "git \(args.joined(separator: " ")) failed (\(result.exitCode))\nstderr: \(result.stderr)"
            )
            throw NSError(
                domain: "VchCLISmokeTests.git", code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
    }

    private func captureGit(
        _ args: [String], cwd: String, env: [String: String]
    ) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(
            data: out.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: err.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return Result(
            exitCode: proc.terminationStatus,
            stdout: stdout, stderr: stderr
        )
    }
}

// `WorkspaceLocator` resolves paths via `git rev-parse --show-toplevel`,
// which on macOS returns the `realpath(3)` form (e.g. `/private/var/...`
// rather than `/var/...`). Mirror that here so path equality checks
// against vch's stdout aren't dominated by the `/var → /private/var`
// symlink. `URL.resolvingSymlinksInPath` is not enough: it strips
// `/private` in some macOS versions, which is the opposite of what
// git does.
private extension String {
    func resolvingSymlinks() throws -> String {
        guard let buf = realpath(self, nil) else {
            return self
        }
        defer { free(buf) }
        return String(cString: buf)
    }
}
