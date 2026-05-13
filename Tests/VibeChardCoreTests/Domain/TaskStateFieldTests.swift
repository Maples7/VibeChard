import XCTest
@testable import VibeChardCore

final class TaskStateFieldTests: XCTestCase {

    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(
        _ name: String = "alpha",
        scheme: String? = nil,
        sim: TaskState.SimulatorRecord? = nil,
        lastBuild: TaskState.BuildRecord? = nil,
        lastTest: TaskState.TestRecord? = nil,
        lastExec: TaskState.ExecRecord? = nil,
        lastSync: TaskState.SyncRecord? = nil,
        worktreeOwnership: TaskState.WorktreeOwnership? = nil
    ) -> TaskState {
        TaskState(
            name: name, branch: "agent/\(name)",
            createdAt: createdAt, baseRef: "deadbee",
            scheme: scheme, simulator: sim,
            lastBuild: lastBuild, lastTest: lastTest,
            lastExec: lastExec, lastSync: lastSync,
            worktreeOwnership: worktreeOwnership
        )
    }

    // MARK: - basic top-level fields

    func testLooksUpScalarFields() {
        let s = state(scheme: "App")
        let path = "/repos/Demo-alpha"
        XCTAssertEqual(TaskStateField.lookup("name", in: s, worktreePath: path),
                       .value("alpha"))
        XCTAssertEqual(TaskStateField.lookup("branch", in: s, worktreePath: path),
                       .value("agent/alpha"))
        XCTAssertEqual(TaskStateField.lookup("path", in: s, worktreePath: path),
                       .value(path))
        XCTAssertEqual(TaskStateField.lookup("scheme", in: s, worktreePath: path),
                       .value("App"))
        XCTAssertEqual(TaskStateField.lookup("schema", in: s, worktreePath: path),
                       .value("1"))
        XCTAssertEqual(TaskStateField.lookup("worktreeOwnership", in: s, worktreePath: path),
                       .value("vch-created"))
    }

    func testLooksUpAdoptedWorktreeOwnership() {
        let s = state(worktreeOwnership: .adopted)
        XCTAssertEqual(TaskStateField.lookup("worktreeOwnership", in: s, worktreePath: "/x"),
                       .value("adopted"))
    }

    // MARK: - simulator nesting

    // #4/#11: the `simulator.udid` alias is what scripts in BeanLedger
    // were grepping for by hand. Acceptance-criteria critical.
    func testSimulatorUDIDAlias() {
        let sim = TaskState.SimulatorRecord(
            cloneUDID: "ABCDEF-1234", sourceUDID: "TPL-99",
            name: "iPhone 16 · vch[alpha]",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
        )
        let s = state(sim: sim)
        XCTAssertEqual(TaskStateField.lookup("simulator.udid", in: s, worktreePath: "/x"),
                       .value("ABCDEF-1234"))
        XCTAssertEqual(TaskStateField.lookup("simulator.cloneUDID", in: s, worktreePath: "/x"),
                       .value("ABCDEF-1234"))
        XCTAssertEqual(TaskStateField.lookup("simulator.sourceUDID", in: s, worktreePath: "/x"),
                       .value("TPL-99"))
        XCTAssertEqual(TaskStateField.lookup("simulator.templateName", in: s, worktreePath: "/x"),
                       .value("iPhone 16"))
    }

    func testSimulatorRuntimeFormatsAsHumanReadable() {
        let sim = TaskState.SimulatorRecord(
            cloneUDID: "C", sourceUDID: "S", name: "n",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
        )
        let s = state(sim: sim)
        XCTAssertEqual(TaskStateField.lookup("simulator.runtime", in: s, worktreePath: "/x"),
                       .value("iOS 26.4"))
        XCTAssertEqual(TaskStateField.lookup("simulator.runtimeIdentifier", in: s, worktreePath: "/x"),
                       .value("com.apple.CoreSimulator.SimRuntime.iOS-26-4"))
    }

    // #47 follow-up: scripts and agents need to be able to tell
    // apart a warm-template-cloned task from an Apple-template one
    // (e.g. to skip warming logic on already-warm tasks). The lookup
    // emits the rawValue so dotted-path output stays stable.
    func testSimulatorSourceKindLookup() {
        let warmSim = TaskState.SimulatorRecord(
            cloneUDID: "C", sourceUDID: "S", name: "n",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            sourceKind: .warmTemplate
        )
        XCTAssertEqual(
            TaskStateField.lookup("simulator.sourceKind",
                                  in: state(sim: warmSim), worktreePath: "/x"),
            .value("warm-template"))

        let appleSim = TaskState.SimulatorRecord(
            cloneUDID: "C", sourceUDID: "S", name: "n",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            sourceKind: .appleTemplate
        )
        XCTAssertEqual(
            TaskStateField.lookup("simulator.sourceKind",
                                  in: state(sim: appleSim), worktreePath: "/x"),
            .value("apple-template"))

        // Legacy state.json (sourceKind nil) → unset, not unknown.
        let legacySim = TaskState.SimulatorRecord(
            cloneUDID: "C", sourceUDID: "S", name: "n",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
        )
        XCTAssertEqual(
            TaskStateField.lookup("simulator.sourceKind",
                                  in: state(sim: legacySim), worktreePath: "/x"),
            .unset)
    }

    // #99: `simulator.udid` / `simulator.*` dotted-path lookups
    // continue to read the legacy `simulator` field. On v0.7+
    // multi-binding tasks the legacy field is mirrored to the FIRST
    // binding (downgrade safety, see `TaskState.setSimulators`), so
    // `vch state <task> --field simulator.udid` deterministically
    // returns the first binding's UDID. Scripts that need a non-first
    // binding fall back to `vch sim info --device <name> --json`.
    // This test pins that contract — if a future refactor accidentally
    // changes which binding `simulator.*` reads, this will catch it.
    func testSimulatorDottedPathReturnsFirstBindingOnMultiBindingTask() {
        var s = state()
        let ios = TaskState.SimulatorRecord(
            cloneUDID: "IOS-CLONE", sourceUDID: "IOS-SRC",
            name: "iPhone 16-vch-alpha",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
        )
        let watch = TaskState.SimulatorRecord(
            cloneUDID: "WATCH-CLONE", sourceUDID: "WATCH-SRC",
            name: "Apple Watch Series 10-vch-alpha",
            templateName: "Apple Watch Series 10",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"
        )
        s.setSimulators([ios, watch])

        XCTAssertEqual(
            TaskStateField.lookup("simulator.udid", in: s, worktreePath: "/x"),
            .value("IOS-CLONE"),
            "dotted-path lookup must return the first binding's UDID"
        )
        XCTAssertEqual(
            TaskStateField.lookup("simulator.templateName", in: s, worktreePath: "/x"),
            .value("iPhone 16")
        )
        XCTAssertEqual(
            TaskStateField.lookup("simulator.runtimeIdentifier", in: s, worktreePath: "/x"),
            .value("com.apple.CoreSimulator.SimRuntime.iOS-18-0")
        )
    }

    // MARK: - unset vs unknown distinction

    func testReturnsUnsetForKnownFieldsThatAreNil() {
        let s = state() // no scheme, no simulator, no last anything
        XCTAssertEqual(TaskStateField.lookup("scheme", in: s, worktreePath: "/x"), .unset)
        XCTAssertEqual(TaskStateField.lookup("simulator.udid", in: s, worktreePath: "/x"), .unset)
        XCTAssertEqual(TaskStateField.lookup("lastTest.success", in: s, worktreePath: "/x"), .unset)
    }

    func testReturnsUnknownForTyposAndUnrecognizedPaths() {
        let s = state()
        XCTAssertEqual(TaskStateField.lookup("simulator.uuid", in: s, worktreePath: "/x"), .unknown)
        XCTAssertEqual(TaskStateField.lookup("foo.bar", in: s, worktreePath: "/x"), .unknown)
        XCTAssertEqual(TaskStateField.lookup("", in: s, worktreePath: "/x"), .unknown)
    }

    // MARK: - lastBuild / lastTest / lastExec

    func testLastBuildAndTestScalars() {
        let finished = Date(timeIntervalSince1970: 1_700_000_500)
        let s = state(
            lastBuild: .init(finishedAt: finished, durationSeconds: 12.5, success: true),
            lastTest: .init(finishedAt: finished, durationSeconds: 33.123,
                            success: false,
                            resultBundlePath: "/wt/.agent-build/Result.xcresult")
        )
        XCTAssertEqual(TaskStateField.lookup("lastBuild.success", in: s, worktreePath: "/x"),
                       .value("true"))
        XCTAssertEqual(TaskStateField.lookup("lastBuild.durationSeconds", in: s, worktreePath: "/x"),
                       .value("12.500"))
        XCTAssertEqual(TaskStateField.lookup("lastTest.success", in: s, worktreePath: "/x"),
                       .value("false"))
        XCTAssertEqual(TaskStateField.lookup("lastTest.resultBundlePath", in: s, worktreePath: "/x"),
                       .value("/wt/.agent-build/Result.xcresult"))
    }

    func testLastExecExitCodeIsScalar() {
        let s = state(
            lastExec: .init(command: "$SHELL",
                            startedAt: createdAt,
                            exitedAt: createdAt.addingTimeInterval(60),
                            exitCode: 0)
        )
        XCTAssertEqual(TaskStateField.lookup("lastExec.exitCode", in: s, worktreePath: "/x"),
                       .value("0"))
        XCTAssertEqual(TaskStateField.lookup("lastExec.command", in: s, worktreePath: "/x"),
                       .value("$SHELL"))
    }

    func testLastSyncFieldsAreScalars() {
        let finished = Date(timeIntervalSince1970: 1_700_000_500)
        let s = state(
            lastSync: .init(
                finishedAt: finished,
                baseSHA: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                baseLabel: "origin/main",
                strategy: "rebase",
                appliedCommits: 4,
                durationSeconds: 1.234
            )
        )
        XCTAssertEqual(TaskStateField.lookup("lastSync.baseSHA", in: s, worktreePath: "/x"),
                       .value("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"))
        XCTAssertEqual(TaskStateField.lookup("lastSync.baseLabel", in: s, worktreePath: "/x"),
                       .value("origin/main"))
        XCTAssertEqual(TaskStateField.lookup("lastSync.strategy", in: s, worktreePath: "/x"),
                       .value("rebase"))
        XCTAssertEqual(TaskStateField.lookup("lastSync.appliedCommits", in: s, worktreePath: "/x"),
                       .value("4"))
        XCTAssertEqual(TaskStateField.lookup("lastSync.durationSeconds", in: s, worktreePath: "/x"),
                       .value("1.234"))
    }

    func testLastSyncUnsetWhenAbsent() {
        let s = state()
        XCTAssertEqual(TaskStateField.lookup("lastSync.baseSHA", in: s, worktreePath: "/x"),
                       .unset)
        XCTAssertEqual(TaskStateField.lookup("lastSync.appliedCommits", in: s, worktreePath: "/x"),
                       .unset)
    }

    // MARK: - knownset registration

    func testKnownContainsEveryFieldThisFileTests() {
        // Tripwire: if someone adds a new lookup case but forgets to
        // register it, this fails fast with a clear pointer.
        for f in [
            "name", "branch", "path", "base", "schema", "scheme",
            "worktreeOwnership", "createdAt",
            "simulator.udid", "simulator.cloneUDID", "simulator.runtime",
            "simulator.sourceKind",
            "lastBuild.success", "lastTest.resultBundlePath", "lastExec.exitCode",
            "lastSync.baseSHA", "lastSync.baseLabel", "lastSync.strategy",
            "lastSync.appliedCommits", "lastSync.durationSeconds",
            "lastSync.finishedAt",
        ] {
            XCTAssertTrue(TaskStateField.known.contains(f),
                          "field '\(f)' must be in TaskStateField.known")
        }
    }
}
