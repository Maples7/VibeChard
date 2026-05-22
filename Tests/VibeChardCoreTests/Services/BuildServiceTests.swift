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

    func testPrepareBuildPassesProjectContextToXcodebuild() throws {
        let (service, _) = makeService(seedingTask: "alpha")
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(
                scheme: "App",
                xcodebuildContainer: .project("Apps/App/App.xcodeproj")
            ),
            baseEnv: [:]
        )

        XCTAssertEqual(Array(plan.argv.prefix(5)), [
            "xcodebuild",
            "-project", "Apps/App/App.xcodeproj",
            "-scheme", "App",
        ])
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

    // MARK: - DEVELOPER_DIR injection (#31)

    func testPrepareBuildInjectsDeveloperDirFromResolverWhenAbsent() throws {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(workspace.worktreePath(for: try TaskName("alpha")))
        let service = BuildService(
            workspace: workspace, fs: fs, simulator: nil,
            developerDir: StubDeveloperDir("/Apps/Xcode.app/Contents/Developer")
        )
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "App"),
            baseEnv: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(plan.env["DEVELOPER_DIR"],
                       "/Apps/Xcode.app/Contents/Developer")
    }

    func testPrepareBuildPreservesUserDeveloperDirOverride() throws {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(workspace.worktreePath(for: try TaskName("alpha")))
        let service = BuildService(
            workspace: workspace, fs: fs, simulator: nil,
            developerDir: StubDeveloperDir("/Apps/Xcode.app/Contents/Developer")
        )
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "App"),
            baseEnv: [
                "PATH": "/usr/bin",
                "DEVELOPER_DIR": "/Custom/Xcode-beta.app/Contents/Developer",
            ]
        )
        XCTAssertEqual(plan.env["DEVELOPER_DIR"],
                       "/Custom/Xcode-beta.app/Contents/Developer")
    }

    func testPrepareBuildOmitsDeveloperDirWhenNoResolver() throws {
        // Default init (no resolver, today's behavior) must stay
        // deterministic for the existing unit test corpus.
        let (service, _) = makeService(seedingTask: "alpha")
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "App"),
            baseEnv: ["PATH": "/usr/bin"]
        )
        XCTAssertNil(plan.env["DEVELOPER_DIR"])
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

    func testRecordTestPersistsExtraArgs() throws {
        // #46: --rerun replays the recorded args, so recordTest must
        // round-trip them through .vch/state.json verbatim — including
        // empty arrays, which mean "ran with no extra args" (distinct
        // from `nil`, which means "legacy state.json that predates
        // this field").
        let (service, fs) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let outcome = BuildOutcome(success: false, durationSeconds: 4.0,
                                   finishedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let args = ["-only-testing:Tests/SuiteA/testFoo", "-parallel-testing-enabled", "NO"]
        try service.recordTest(task: try TaskName("alpha"),
                               outcome: outcome, scheme: nil, extraArgs: args)
        let state = try TaskState.parse(
            fs.readFile(forTesting: "/repos/Demo-alpha/.vch/state.json")
        )
        XCTAssertEqual(state.lastTest?.extraArgs, args)
    }

    func testRecordTestPersistsEmptyExtraArgsDistinctFromNil() throws {
        // When the user invokes `vch test foo` with no `-- ...`
        // tail, recordTest should write `extraArgs: []` so a later
        // `--rerun` knows the prior run had no extras (vs. it being
        // a legacy state.json with no field at all).
        let (service, fs) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let outcome = BuildOutcome(success: true, durationSeconds: 1.0,
                                   finishedAt: Date(timeIntervalSince1970: 1_700_000_200))
        try service.recordTest(task: try TaskName("alpha"),
                               outcome: outcome, scheme: nil, extraArgs: [])
        let state = try TaskState.parse(
            fs.readFile(forTesting: "/repos/Demo-alpha/.vch/state.json")
        )
        XCTAssertEqual(state.lastTest?.extraArgs, [])
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
            resolvedSimulatorPlatform: .iOS,
            baseEnv: ["PATH": "/usr/bin"]
        )
        // Destination is `id=`, NOT `name=`.
        XCTAssertTrue(plan.argv.contains("-destination"))
        let i = plan.argv.firstIndex(of: "-destination")!
        XCTAssertEqual(plan.argv[i + 1], "platform=iOS Simulator,arch=\(BuildPlanner.hostArch),id=CLONE-UDID-1")
        XCTAssertFalse(plan.argv.contains { $0.contains("name=iPhone 16") })

        // SIMCTL_CHILD_SIMULATOR_UDID set so embedded simctl/test
        // tooling pins to the clone.
        XCTAssertEqual(plan.env["SIMCTL_CHILD_SIMULATOR_UDID"], "CLONE-UDID-1")
    }

    func testPrepareBuildEmitsResolvedSimulatorPlatform() throws {
        let (service, _) = makeService(seedingTask: "alpha")
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "WatchApp", device: "Apple Watch Series 10 (46mm)"),
            resolvedSimulatorUDID: "WATCH-UDID-1",
            resolvedSimulatorPlatform: .watchOS,
            baseEnv: [:]
        )
        let i = plan.argv.firstIndex(of: "-destination")!
        XCTAssertEqual(plan.argv[i + 1], "platform=watchOS Simulator,arch=\(BuildPlanner.hostArch),id=WATCH-UDID-1")
    }

    func testPrepareBuildRefusesUDIDWhenPlatformUnknown() throws {
        let (service, _) = makeService(seedingTask: "alpha")
        XCTAssertThrowsError(try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(scheme: "App", device: "Apple Watch Series 10 (46mm)"),
            resolvedSimulatorUDID: "WATCH-UDID-1",
            baseEnv: [:]
        )) { err in
            guard case VibeChardError.simulatorPlatformUnknown = err else {
                return XCTFail("expected simulatorPlatformUnknown, got \(err)")
            }
        }
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
        XCTAssertEqual(plan.argv[i + 1], "platform=iOS Simulator,arch=\(BuildPlanner.hostArch),name=iPhone 16")
        XCTAssertNil(plan.env["SIMCTL_CHILD_SIMULATOR_UDID"])
    }

    func testPrepareBuildUsesRuntimePlatformForNoSimNameDestination() throws {
        let (service, _) = makeService(seedingTask: "alpha")
        let plan = try service.prepareBuild(
            task: try TaskName("alpha"),
            options: .init(
                scheme: "WatchApp",
                device: "Apple Watch Series 10 (46mm)",
                runtime: "watchOS 11.0",
                noSim: true
            ),
            resolvedSimulatorUDID: nil,
            baseEnv: [:]
        )
        let i = plan.argv.firstIndex(of: "-destination")!
        XCTAssertEqual(plan.argv[i + 1], "platform=watchOS Simulator,arch=\(BuildPlanner.hostArch),name=Apple Watch Series 10 (46mm)")
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
        simctl.devices = [SimDevice(
            udid: "U-1",
            name: "iPhone 16-vch-alpha",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            runtimeVersion: .init(major: 26, minor: 5),
            isAvailable: true,
            state: "Booted"
        )]
        let sim = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)
        let service = BuildService(workspace: workspace, fs: fs, simulator: sim)
        try service.bootSimulator(.init(udid: "U-1", name: "iPhone 16-vch-alpha", createdNow: false))
        XCTAssertEqual(simctl.bootCalls, ["U-1"])
    }

    func testBootSimulatorFailsWhenCloneRemainsShutdownAfterBootstatus() throws {
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        let task = try TaskName("alpha")
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedDirectory(workspace.vchDir(for: task))
        fs.seedFile(workspace.statePath(for: task),
                    data: try emptyState("alpha").jsonData())
        let simctl = FakeSimctl()
        simctl.devices = [SimDevice(
            udid: "U-1",
            name: "iPhone 16-vch-alpha",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            runtimeVersion: .init(major: 26, minor: 5),
            isAvailable: true,
            state: "Shutdown"
        )]
        let sim = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)
        let service = BuildService(workspace: workspace, fs: fs, simulator: sim)

        XCTAssertThrowsError(try service.bootSimulator(.init(
            udid: "U-1",
            name: "iPhone 16-vch-alpha",
            createdNow: false
        ))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("iPhone 16-vch-alpha"), message)
            XCTAssertTrue(message.contains("Shutdown"), message)
            XCTAssertTrue(message.contains("xcrun simctl bootstatus U-1 -b"), message)
        }
        XCTAssertEqual(simctl.bootCalls, ["U-1"])
    }

    func testInferSimulatorPlatformReadsBuildSettings() throws {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        let task = try TaskName("alpha")
        fs.seedDirectory(workspace.worktreePath(for: task))
        let lister = FakeBuildSettingsLister(stub: Data(#"""
        [
          {
            "target": "WatchApp",
            "buildSettings": {
              "PLATFORM_NAME": "watchsimulator"
            }
          }
        ]
        """#.utf8))
        let service = BuildService(
            workspace: workspace,
            fs: fs,
            settingsLister: lister
        )
        XCTAssertEqual(
            service.inferSimulatorPlatform(
                task: task,
                scheme: "WatchApp",
                configuration: nil
            ),
            .watchOS
        )
        XCTAssertEqual(lister.lastCwd, workspace.worktreePath(for: task))
                XCTAssertNil(lister.lastXcodebuildContainer)
        XCTAssertNil(lister.lastDestination)
    }

        func testInferSimulatorPlatformPassesProjectContextToBuildSettingsProbe() throws {
                let fs = InMemoryFileSystem()
                let workspace = Workspace(mainWorktreePath: mainRepo)
                fs.seedDirectory(mainRepo)
                let task = try TaskName("alpha")
                fs.seedDirectory(workspace.worktreePath(for: task))
                let lister = FakeBuildSettingsLister(stub: Data(#"""
                [
                    {
                        "target": "App",
                        "buildSettings": {
                            "PLATFORM_NAME": "iphonesimulator"
                        }
                    }
                ]
                """#.utf8))
                let service = BuildService(
                        workspace: workspace,
                        fs: fs,
                        settingsLister: lister
                )

                XCTAssertEqual(
                        service.inferSimulatorPlatform(
                                task: task,
                                scheme: "App",
                                configuration: nil,
                                xcodebuildContainer: .project("Apps/App/App.xcodeproj")
                        ),
                        .iOS
                )
                XCTAssertEqual(lister.lastXcodebuildContainer, .project("Apps/App/App.xcodeproj"))
        }

    func testDestinationPlatformHintSkipsBuildSettingsWhenExplicitLazyCloneDeviceCanResolvePlatform() throws {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        let task = try TaskName("alpha")
        fs.seedDirectory(workspace.worktreePath(for: task))
        let lister = FakeBuildSettingsLister(stub: Data(#"""
        [
          {
            "target": "WatchApp",
            "buildSettings": {
              "PLATFORM_NAME": "watchsimulator"
            }
          }
        ]
        """#.utf8))
        let service = BuildService(
            workspace: workspace,
            fs: fs,
            settingsLister: lister
        )

        let platform = service.destinationPlatformHint(
            task: task,
            scheme: "WatchApp",
            configuration: nil,
            requestedDevice: "Apple Watch Series 10 (46mm)",
            requestedRuntime: nil,
            noSim: false
        )

        XCTAssertNil(platform)
        XCTAssertNil(lister.lastCwd,
                     "explicit lazy-clone --device should not run a build-settings probe")
    }

    func testDestinationPlatformHintUsesRuntimeBeforeBuildSettingsProbe() throws {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        let task = try TaskName("alpha")
        fs.seedDirectory(workspace.worktreePath(for: task))
        let lister = FakeBuildSettingsLister(stub: Data(#"""
        [
          {
            "target": "WrongScheme",
            "buildSettings": {
              "PLATFORM_NAME": "iphonesimulator"
            }
          }
        ]
        """#.utf8))
        let service = BuildService(
            workspace: workspace,
            fs: fs,
            settingsLister: lister
        )

        let platform = service.destinationPlatformHint(
            task: task,
            scheme: "WrongScheme",
            configuration: nil,
            requestedDevice: nil,
            requestedRuntime: "watchOS 11.5",
            noSim: false
        )

        XCTAssertEqual(platform, .watchOS)
        XCTAssertNil(lister.lastCwd,
                     "runtime carries the platform; no build-settings probe is needed")
    }

    func testResolveSimulatorUsesInferredSchemePlatformToDisambiguateTwoBindings() throws {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        let task = try TaskName("alpha")
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedDirectory(workspace.vchDir(for: task))
        var seed = emptyState("alpha")
        seed.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "WATCH-CLONE",
                sourceUDID: "WATCH-TPL",
                name: "Apple Watch Series 10-vch-alpha",
                templateName: "Apple Watch Series 10 (46mm)",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"
            ),
            TaskState.SimulatorRecord(
                cloneUDID: "IOS-CLONE",
                sourceUDID: "IOS-TPL",
                name: "iPhone 16-vch-alpha",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
            ),
        ])
        fs.seedFile(workspace.statePath(for: task), data: try seed.jsonData())
        let lister = FakeBuildSettingsLister(stub: Data(#"""
        [
          {
            "target": "WatchApp",
            "buildSettings": {
              "PLATFORM_NAME": "watchsimulator"
            }
          }
        ]
        """#.utf8))
        let simctl = FakeSimctl()
        simctl.allDevicesOverride = [
            SimDevice(udid: "WATCH-CLONE", name: "Apple Watch Series 10-vch-alpha",
                      runtime: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
                      runtimeVersion: .init(platform: .watchOS, major: 11, minor: 0),
                      isAvailable: true),
            SimDevice(udid: "IOS-CLONE", name: "iPhone 16-vch-alpha",
                      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
                      runtimeVersion: .init(major: 18, minor: 2),
                      isAvailable: true),
        ]
        let sim = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)
        let service = BuildService(
            workspace: workspace,
            fs: fs,
            simulator: sim,
            settingsLister: lister
        )
        let platform = service.destinationPlatformHint(
            task: task,
            scheme: "WatchApp",
            configuration: nil,
            requestedDevice: nil,
            requestedRuntime: nil,
            noSim: false
        )

        let resolved = try service.resolveSimulator(
            task: task,
            requestedDevice: nil,
            requestedRuntime: nil,
            requestedPlatform: platform,
            noSim: false
        )

        XCTAssertEqual(platform, .watchOS)
        XCTAssertEqual(resolved?.udid, "WATCH-CLONE")
        XCTAssertEqual(resolved?.platform, .watchOS)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    // MARK: - adopted worktrees at arbitrary paths (#98 follow-up)

    /// For a task adopted via `vch new [<name>] --adopt-current`, the
    /// downstream services receive a `Workspace` whose
    /// `taskWorktreePaths` map overrides the conventional
    /// `<repo>-<task>` path. Every path BuildService computes —
    /// `cwd`, `.agent-build` subdirs, the env vars it sets — has to
    /// resolve to the override. Regression guard: if `BuildService`
    /// ever re-derives a path directly from `task.raw` instead of
    /// going through `workspace.<dir>(for:)`, this test will catch it.
    func testPrepareBuildResolvesAdoptedWorktreePathAndIsolationDirs() throws {
        let adoptedPath = "/Users/me/codex-session"
        let task = try TaskName("alpha")
        let workspace = Workspace(mainWorktreePath: mainRepo)
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(adoptedPath)
        fs.seedDirectory(workspace.vchDir(for: task))
        fs.seedFile(workspace.statePath(for: task),
                    data: try emptyState("alpha").jsonData())
        let service = BuildService(workspace: workspace, fs: fs)

        let plan = try service.prepareBuild(
            task: task,
            options: .init(scheme: "App"),
            baseEnv: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(plan.cwd, adoptedPath,
                       "cwd must be the adopted path, NOT \(mainRepo)-alpha")
        XCTAssertEqual(plan.env["VCH_TASK_ROOT"], adoptedPath)
        XCTAssertEqual(plan.env["CLANG_MODULE_CACHE_PATH"],
                       "\(adoptedPath)/.agent-build/ModuleCache")
        XCTAssertEqual(plan.env["SWIFTPM_CACHE_DIR"],
                       "\(adoptedPath)/.agent-build/SwiftPM")
        XCTAssertTrue(fs.directoryExists(at: "\(adoptedPath)/.agent-build/DerivedData"),
                      "DerivedData must be inside the adopted worktree")
        XCTAssertTrue(fs.directoryExists(at: "\(adoptedPath)/.agent-build/SwiftPM"))
        // Crucial negative: the conventional path must NOT have been
        // touched. If it has, BuildService is leaking caches outside
        // the adopted worktree.
        XCTAssertFalse(fs.directoryExists(at: "\(mainRepo)-alpha"),
                       "BuildService leaked the conventional <repo>-<task> path")
    }

    /// `prepareTest` lays down the result bundle and adds
    /// `-resultBundlePath`. Same override propagation requirement —
    /// regression test for a separate code path inside BuildService.
    func testPrepareTestPointsResultBundleInsideAdoptedWorktree() throws {
        let adoptedPath = "/Users/me/codex-session"
        let task = try TaskName("alpha")
        let workspace = Workspace(mainWorktreePath: mainRepo)
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(adoptedPath)
        fs.seedDirectory(workspace.vchDir(for: task))
        fs.seedFile(workspace.statePath(for: task),
                    data: try emptyState("alpha").jsonData())
        let service = BuildService(workspace: workspace, fs: fs)

        let plan = try service.prepareTest(
            task: task,
            options: .init(scheme: "App", device: "iPhone 16"),
            baseEnv: [:]
        )
        XCTAssertTrue(plan.argv.contains("-resultBundlePath"))
        XCTAssertTrue(
            plan.argv.contains("\(adoptedPath)/.agent-build/Result.xcresult"),
            "result bundle path must live inside the adopted worktree; argv=\(plan.argv)"
        )
        XCTAssertEqual(plan.cwd, adoptedPath)
    }
}

// Tiny ergonomic helper local to this file so the assertion above
// doesn't need a try inside an XCTAssertEqual().
private extension InMemoryFileSystem {
    func readFile(forTesting path: String) -> Data {
        (try? readFile(at: path)) ?? Data()
    }
}

private struct StubDeveloperDir: DeveloperDirResolver {
    let value: String?
    init(_ value: String?) { self.value = value }
    func resolve() -> String? { value }
}
