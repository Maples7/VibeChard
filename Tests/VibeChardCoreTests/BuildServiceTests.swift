import XCTest
@testable import VibeChardCore

final class BuildServiceTests: XCTestCase {

    private let mainRepo = "/repos/Demo"

    private func makeService(
        seedingTask raw: String? = nil,
        seedingState: TaskState? = nil
    ) -> (BuildService, InMemoryFileSystem) {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        if let raw {
            let task = try! TaskName(raw)
            fs.seedDirectory(workspace.worktreePath(for: task))
            fs.seedDirectory(workspace.vchDir(for: task))
            if let state = seedingState {
                fs.seedFile(workspace.statePath(for: task),
                            data: try! state.jsonData())
            }
        }
        return (BuildService(workspace: workspace, fs: fs), fs)
    }

    private func emptyState(_ name: String) -> TaskState {
        TaskState(name: name, branch: "agent/\(name)",
                  createdAt: Date(timeIntervalSince1970: 1_699_000_000),
                  baseRef: "abc123")
    }

    // MARK: - prepareBuild

    func testPrepareBuildCreatesScratchDirsAndProducesXcodebuildArgv() throws {
        let (service, fs) = makeService(seedingTask: "alpha")
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "App"),
            baseEnv: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(plan.cwd, "/repos/Demo-alpha")
        XCTAssertEqual(plan.argv.first, "xcodebuild")
        XCTAssertTrue(plan.argv.contains("-scheme"))
        XCTAssertTrue(plan.argv.contains("App"))
        XCTAssertEqual(plan.argv.last, "build")

        XCTAssertTrue(fs.directoryExists(at: "/repos/Demo-alpha/.agent-build/DerivedData"))
        XCTAssertTrue(fs.directoryExists(at: "/repos/Demo-alpha/.agent-build/SwiftPM"))
        XCTAssertTrue(fs.directoryExists(at: "/repos/Demo-alpha/.agent-build/ModuleCache"))
        // M4 invokes xcodebuild directly — must NOT install shim symlinks.
        XCTAssertEqual(plan.installedShimSymlinks, [])
    }

    func testPrepareBuildSetsToolEnvButNotShimEnv() throws {
        let (service, _) = makeService(seedingTask: "alpha")
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "App"),
            baseEnv: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(plan.env["CLANG_MODULE_CACHE_PATH"],
                       "/repos/Demo-alpha/.agent-build/ModuleCache")
        XCTAssertEqual(plan.env["SWIFTPM_CACHE_DIR"],
                       "/repos/Demo-alpha/.agent-build/SwiftPM")
        XCTAssertEqual(plan.env["VCH_TASK_NAME"], "alpha")
        XCTAssertEqual(plan.env["VCH_TASK_ROOT"], "/repos/Demo-alpha")
        // Shim-side vars: M4 doesn't go through the shim, so they must
        // be absent so a stray xcodebuild call inside extraArgs doesn't
        // double-inject.
        XCTAssertNil(plan.env["VCH_DERIVED_DATA_PATH"])
        XCTAssertNil(plan.env["VCH_SPM_CLONE_DIR"])
        XCTAssertNil(plan.env["VCH_RESULT_BUNDLE_PATH"])
        // PATH untouched (no shim bin prepend in M4).
        XCTAssertEqual(plan.env["PATH"], "/usr/bin")
    }

    func testPrepareTestEmitsResultBundleAndCleansStaleBundle() throws {
        let (service, fs) = makeService(seedingTask: "alpha")
        // Seed a stale result bundle on the path.
        fs.seedDirectory("/repos/Demo-alpha/.agent-build/Result.xcresult")
        XCTAssertTrue(fs.directoryExists(at: "/repos/Demo-alpha/.agent-build/Result.xcresult"))

        let plan = try service.prepareTest(
            task: try TaskName("alpha"),
            options: .init(scheme: "App", device: "iPhone 16"),
            baseEnv: [:]
        )
        XCTAssertTrue(plan.argv.contains("-resultBundlePath"))
        XCTAssertTrue(plan.argv.contains("/repos/Demo-alpha/.agent-build/Result.xcresult"))
        XCTAssertTrue(plan.argv.contains("-destination"))
        XCTAssertEqual(plan.argv.last, "test")
        // Stale bundle wiped (xcodebuild refuses to overwrite).
        XCTAssertFalse(fs.directoryExists(at: "/repos/Demo-alpha/.agent-build/Result.xcresult"))
    }

    func testPrepareThrowsTaskNotFoundWhenWorktreeMissing() throws {
        let (service, _) = makeService(seedingTask: nil)
        XCTAssertThrowsError(try service.prepareBuild(
            task: try TaskName("ghost"),
            options: .init(),
            baseEnv: [:]
        )) { error in
            guard case VibeChardError.taskNotFound = error else {
                return XCTFail("expected taskNotFound, got \(error)")
            }
        }
    }

    // MARK: - recordBuild / recordTest

    func testRecordBuildPersistsLastBuildAndUpdatesScheme() throws {
        let (service, fs) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let outcome = BuildOutcome(success: true, durationSeconds: 12.5,
                                   finishedAt: Date(timeIntervalSince1970: 1_700_000_100))
        try service.recordBuild(task: try TaskName("alpha"),
                                outcome: outcome, scheme: "App")

        let data = try fs.readFile(at: "/repos/Demo-alpha/.vch/state.json")
        let state = try TaskState.parse(data)
        XCTAssertEqual(state.scheme, "App")
        XCTAssertEqual(state.lastBuild?.success, true)
        XCTAssertEqual(state.lastBuild?.durationSeconds ?? -1, 12.5, accuracy: 0.001)
        // recordBuild must NOT touch lastTest.
        XCTAssertNil(state.lastTest)
    }

    func testRecordTestPersistsResultBundlePath() throws {
        let (service, fs) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let outcome = BuildOutcome(success: false, durationSeconds: 4.0,
                                   finishedAt: Date(timeIntervalSince1970: 1_700_000_200))
        try service.recordTest(task: try TaskName("alpha"),
                               outcome: outcome, scheme: nil)
        let state = try TaskState.parse(
            fs.readFile(forTesting: "/repos/Demo-alpha/.vch/state.json")
        )
        XCTAssertEqual(state.lastTest?.success, false)
        XCTAssertEqual(state.lastTest?.resultBundlePath,
                       "/repos/Demo-alpha/.agent-build/Result.xcresult")
        // Caller passed nil scheme — existing scheme (also nil here) preserved.
        XCTAssertNil(state.scheme)
    }

    func testRecordThrowsWhenStateFileMissing() throws {
        let (service, _) = makeService(seedingTask: "alpha")
        let outcome = BuildOutcome(success: true, durationSeconds: 1,
                                   finishedAt: Date())
        XCTAssertThrowsError(try service.recordBuild(
            task: try TaskName("alpha"), outcome: outcome, scheme: nil
        )) { error in
            guard case VibeChardError.stateFileCorrupt = error else {
                return XCTFail("expected stateFileCorrupt, got \(error)")
            }
        }
    }

    // MARK: - simulator integration (M5)

    func testResolveSimulatorReturnsNilWhenNoSimFlag() throws {
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        let task = try TaskName("alpha")
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedDirectory(workspace.vchDir(for: task))
        fs.seedFile(workspace.statePath(for: task),
                    data: try emptyState("alpha").jsonData())
        let simctl = FakeSimctl()
        let sim = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)
        let service = BuildService(workspace: workspace, fs: fs, simulator: sim)
        let resolved = try service.resolveSimulator(
            task: task, requestedDevice: "iPhone 16", noSim: true
        )
        XCTAssertNil(resolved)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    func testResolveSimulatorReturnsNilWhenServiceUnconfigured() throws {
        let (service, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        // Default service has no SimulatorService injected.
        let resolved = try service.resolveSimulator(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16",
            noSim: false
        )
        XCTAssertNil(resolved)
    }

    func testPrepareBuildEmitsIDDestinationAndSimctlChildEnvWhenResolved() throws {
        let (service, _) = makeService(seedingTask: "alpha")
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "App", device: "iPhone 16"),
            resolvedSimulatorUDID: "CLONE-UDID-1",
            baseEnv: ["PATH": "/usr/bin"]
        )
        // Destination is `id=`, NOT `name=`.
        XCTAssertTrue(plan.argv.contains("-destination"))
        let i = plan.argv.firstIndex(of: "-destination")!
        XCTAssertEqual(plan.argv[i + 1], "platform=iOS Simulator,id=CLONE-UDID-1")
        XCTAssertFalse(plan.argv.contains { $0.contains("name=iPhone 16") })

        // SIMCTL_CHILD_SIMULATOR_UDID set so embedded simctl/test
        // tooling pins to the clone.
        XCTAssertEqual(plan.env["SIMCTL_CHILD_SIMULATOR_UDID"], "CLONE-UDID-1")
    }

    func testPrepareBuildFallsBackToNameDestinationWhenNoUDID() throws {
        let (service, _) = makeService(seedingTask: "alpha")
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "App", device: "iPhone 16", noSim: true),
            resolvedSimulatorUDID: nil,
            baseEnv: [:]
        )
        let i = plan.argv.firstIndex(of: "-destination")!
        XCTAssertEqual(plan.argv[i + 1], "platform=iOS Simulator,name=iPhone 16")
        XCTAssertNil(plan.env["SIMCTL_CHILD_SIMULATOR_UDID"])
    }

    func testBootSimulatorDelegatesToSimctl() throws {
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        let task = try TaskName("alpha")
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedDirectory(workspace.vchDir(for: task))
        fs.seedFile(workspace.statePath(for: task),
                    data: try emptyState("alpha").jsonData())
        let simctl = FakeSimctl()
        let sim = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)
        let service = BuildService(workspace: workspace, fs: fs, simulator: sim)
        try service.bootSimulator(.init(udid: "U-1", name: "x", createdNow: false))
        XCTAssertEqual(simctl.bootCalls, ["U-1"])
    }
}

// Tiny ergonomic helper local to this file so the assertion above
// doesn't need a try inside an XCTAssertEqual().
private extension InMemoryFileSystem {
    func readFile(forTesting path: String) -> Data {
        (try? readFile(at: path)) ?? Data()
    }
}
