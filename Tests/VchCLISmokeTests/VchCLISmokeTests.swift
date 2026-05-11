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
}
