import XCTest
@testable import VibeChardCore

final class TestRerunTests: XCTestCase {
    private let workspace = Workspace(mainWorktreePath: "/repos/Demo")
    private let task = try! TaskName("alpha")
    private let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-17-0"

    private func fixture() throws -> (BuildService, InMemoryFileSystem, FakeSimctl) {
        let fs = InMemoryFileSystem()
        let simctl = FakeSimctl()
        var state = TaskState(name: task.raw, branch: "agent/alpha",
                              createdAt: Date(), baseRef: "abc", scheme: "OtherApp")
        let records: [TaskState.SimulatorRecord] = [
            .init(cloneUDID: "LAST", sourceUDID: "A", name: "iPhone 15-vch-alpha",
                  templateName: "iPhone 15", runtimeIdentifier: runtime),
            .init(cloneUDID: "NEWER", sourceUDID: "B", name: "iPhone 15-vch-alpha",
                  templateName: "iPhone 15",
                  runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"),
            .init(cloneUDID: "OTHER", sourceUDID: "C", name: "iPhone 16-vch-alpha",
                  templateName: "iPhone 16",
                  runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"),
            .init(cloneUDID: "WATCH", sourceUDID: "D", name: "Apple Watch-vch-alpha",
                  templateName: "Apple Watch",
                  runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"),
        ]
        state.setSimulators(records)
        state.lastTest = .init(
            finishedAt: Date(), durationSeconds: 1, success: false,
            resultBundlePath: workspace.resultBundlePath(for: task),
            extraArgs: ["-only-testing:Tests/Suite", "-parallel-testing-enabled", "NO"],
            invocation: .init(scheme: "Tests", xcodebuildContainer: .project("App.xcodeproj"),
                              configuration: "Release", device: "iPhone 15", runtime: "iOS 17.0",
                              simulatorUDID: "LAST")
        )
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())
        simctl.devices = records.map {
            SimDevice(udid: $0.cloneUDID, name: $0.name, runtime: $0.runtimeIdentifier!,
                      runtimeVersion: $0.runtimeVersion, isAvailable: true)
        }
        let simulator = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)
        return (BuildService(workspace: workspace, fs: fs, simulator: simulator), fs, simctl)
    }

    func testBareRerunUsesExactCloneAmongMultipleDevicesRuntimesAndPlatforms() throws {
        let (service, _, simctl) = try fixture()
        let replay = try service.prepareTestRerun(task: task, overrides: .init())
        let clone = try service.resolveSimulator(
            task: task, requestedDevice: replay.options.device,
            requestedRuntime: replay.options.runtime, noSim: replay.options.noSim,
            recordedUDID: replay.simulatorUDID
        )
        let plan = try service.prepareTest(
            task: task, options: replay.options, resolvedSimulatorUDID: clone?.udid,
            resolvedSimulatorPlatform: clone?.platform, baseEnv: [:]
        )
        XCTAssertEqual(clone?.udid, "LAST")
        XCTAssertEqual(replay.options.scheme, "Tests")
        XCTAssertEqual(replay.options.configuration, "Release")
        XCTAssertEqual(replay.options.xcodebuildContainer, .project("App.xcodeproj"))
        XCTAssertTrue(plan.argv.contains("platform=iOS Simulator,arch=\(BuildPlanner.hostArch),id=LAST"))
        XCTAssertTrue(plan.argv.contains("-only-testing:Tests/Suite"))
        XCTAssertTrue(simctl.cloneCalls.isEmpty)
    }

    func testExplicitOverridesReplaceRecordedOptionsIncludingPassthroughEquivalents() throws {
        let (service, fs, _) = try fixture()
        var state = try TaskState.parse(fs.readFile(at: workspace.statePath(for: task)))
        state.lastTest = .init(
            finishedAt: Date(), durationSeconds: 1, success: false, resultBundlePath: nil,
            extraArgs: ["-scheme", "RawOldScheme", "-configuration", "Debug",
                        "-workspace", "Old.xcworkspace", "-destination", "id=OLD",
                        "-parallel-testing-enabled", "NO", "-only-testing:Tests/Suite"],
            invocation: state.lastTest?.invocation
        )
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())

        let replay = try service.prepareTestRerun(
            task: task, overrides: .init(scheme: "NewTests", xcodebuildContainer: .project("New.xcodeproj"),
                                         configuration: "Profile", device: "iPhone 16", runtime: "iOS 18.0")
        )
        XCTAssertEqual(replay.options.scheme, "NewTests")
        XCTAssertEqual(replay.options.configuration, "Profile")
        XCTAssertEqual(replay.options.xcodebuildContainer, .project("New.xcodeproj"))
        XCTAssertEqual(replay.options.device, "iPhone 16")
        XCTAssertEqual(replay.options.runtime, "iOS 18.0")
        XCTAssertNil(replay.simulatorUDID)
        XCTAssertEqual(replay.options.extraArgs,
                       ["-parallel-testing-enabled", "NO", "-only-testing:Tests/Suite"])
    }

    func testRuntimeOverrideKeepsDeviceAndSelectsItsOtherRuntime() throws {
        let (service, _, _) = try fixture()
        let replay = try service.prepareTestRerun(task: task, overrides: .init(runtime: "iOS 18.0"))
        XCTAssertEqual(replay.options.device, "iPhone 15")
        XCTAssertNil(replay.simulatorUDID)
        let clone = try service.resolveSimulator(
            task: task, requestedDevice: replay.options.device,
            requestedRuntime: replay.options.runtime, noSim: replay.options.noSim,
            recordedUDID: replay.simulatorUDID
        )
        XCTAssertEqual(clone?.udid, "NEWER")
    }

    func testPartialOverrideOfRawDestinationRefusesToDropUnknownTargetFields() throws {
        let (service, fs, _) = try fixture()
        var state = try TaskState.parse(fs.readFile(at: workspace.statePath(for: task)))
        state.lastTest = .init(
            finishedAt: Date(), durationSeconds: 1, success: true, resultBundlePath: nil,
            extraArgs: ["-destination", "platform=iOS Simulator,name=iPhone 15,OS=17.0"],
            invocation: .init(noSim: true)
        )
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())
        XCTAssertThrowsError(try service.prepareTestRerun(task: task, overrides: .init(runtime: "iOS 18.0"))) {
            XCTAssertTrue(String(describing: $0).contains("both --device and --runtime"))
        }
        let replay = try service.prepareTestRerun(task: task, overrides: .init(noSim: true))
        XCTAssertEqual(replay.options.extraArgs,
                       ["-destination", "platform=iOS Simulator,name=iPhone 15,OS=17.0"])
    }

    func testSchemeOverrideKeepsRecordedDestination() throws {
        let (service, _, _) = try fixture()
        let replay = try service.prepareTestRerun(task: task, overrides: .init(scheme: "NewTests"))
        XCTAssertEqual(replay.options.scheme, "NewTests")
        XCTAssertEqual(replay.simulatorUDID, "LAST")
        XCTAssertEqual(replay.options.runtime, "iOS 17.0")
    }

    func testWatchRerunKeepsWatchDestinationAmongIOSBindings() throws {
        let (service, _, _) = try fixture()
        try service.recordTest(
            task: task, outcome: .init(success: true, durationSeconds: 1, finishedAt: Date()),
            options: .init(scheme: "WatchTests"),
            resolvedSimulator: .init(udid: "WATCH", name: "Apple Watch-vch-alpha", createdNow: false,
                                     runtime: .init(platform: .watchOS, major: 11, minor: 0))
        )
        let replay = try service.prepareTestRerun(task: task, overrides: .init())
        let clone = try service.resolveSimulator(
            task: task, requestedDevice: replay.options.device, noSim: replay.options.noSim,
            recordedUDID: replay.simulatorUDID
        )
        let plan = try service.prepareTest(
            task: task, options: replay.options, resolvedSimulatorUDID: clone?.udid,
            resolvedSimulatorPlatform: clone?.platform, baseEnv: [:]
        )
        XCTAssertEqual(replay.options.device, "Apple Watch")
        XCTAssertEqual(replay.options.runtime, "watchOS 11.0")
        XCTAssertTrue(plan.argv.contains("platform=watchOS Simulator,arch=\(BuildPlanner.hostArch),id=WATCH"))
    }

    func testRerunFailedOnlyChangesSelectorsAndPreservesDestination() throws {
        let (service, _, _) = try fixture()
        let replay = try service.prepareTestRerun(
            task: task, overrides: .init(), failedOnly: true, reader: FailedResults()
        )
        XCTAssertEqual(replay.failureCount, 1)
        XCTAssertEqual(replay.simulatorUDID, "LAST")
        XCTAssertEqual(replay.options.scheme, "Tests")
        XCTAssertEqual(replay.options.configuration, "Release")
        XCTAssertEqual(replay.options.runtime, "iOS 17.0")
        XCTAssertEqual(replay.options.extraArgs,
                       ["-parallel-testing-enabled", "NO", "-only-testing:Tests/Suite/fails()"])
    }

    func testDeletedOrUnavailableCloneGivesRecoveryHintWithoutSubstitution() throws {
        for unavailable in [false, true] {
            let (service, fs, simctl) = try fixture()
            simctl.devices.removeAll { $0.udid == "LAST" }
            if unavailable {
                simctl.devices.append(.init(udid: "LAST", name: "iPhone 15-vch-alpha", runtime: runtime,
                                             runtimeVersion: .init(major: 17, minor: 0), isAvailable: false))
            }
            let priorState = try fs.readFile(at: workspace.statePath(for: task))
            let replay = try service.prepareTestRerun(task: task, overrides: .init())
            XCTAssertThrowsError(try service.resolveSimulator(
                task: task, requestedDevice: replay.options.device, noSim: replay.options.noSim,
                recordedUDID: replay.simulatorUDID
            )) { error in
                guard case let VibeChardError.testRerunSimulatorUnavailable(name, udid) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(name, "alpha")
                XCTAssertEqual(udid, "LAST")
                XCTAssertEqual((error as? VibeChardError)?.exitCode, ExitCode.business)
                XCTAssertTrue(String(describing: error).contains("--device and --runtime"))
            }
            XCTAssertEqual(try fs.readFile(at: workspace.statePath(for: task)), priorState)
            XCTAssertTrue(simctl.cloneCalls.isEmpty)
            XCTAssertTrue(simctl.bootCalls.isEmpty)
        }
    }

    func testLegacyStateKeepsOldDefaultsAndRecordedExtraArgs() throws {
        let (service, fs, _) = try fixture()
        var state = try TaskState.parse(fs.readFile(at: workspace.statePath(for: task)))
        state.lastTest = .init(finishedAt: Date(), durationSeconds: 1, success: true,
                               resultBundlePath: nil, extraArgs: ["-only-testing:OldTests/Suite"])
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())
        let replay = try service.prepareTestRerun(task: task, overrides: .init(device: "iPhone 15"))
        XCTAssertTrue(replay.usedLegacyState)
        XCTAssertNil(replay.options.scheme)
        XCTAssertEqual(replay.options.device, "iPhone 15")
        XCTAssertEqual(replay.options.extraArgs, ["-only-testing:OldTests/Suite"])
        XCTAssertNil(replay.simulatorUDID)
    }

    func testNoSimOverrideKeepsRecordedNameAndRuntimeWithoutBootingClone() throws {
        let (service, _, simctl) = try fixture()
        let replay = try service.prepareTestRerun(task: task, overrides: .init(noSim: true))
        XCTAssertNil(replay.simulatorUDID)
        XCTAssertNil(try service.resolveSimulator(
            task: task, requestedDevice: replay.options.device, noSim: replay.options.noSim,
            recordedUDID: replay.simulatorUDID
        ))
        let plan = try service.prepareTest(task: task, options: replay.options, baseEnv: [:])
        XCTAssertTrue(plan.argv.contains("platform=iOS Simulator,arch=\(BuildPlanner.hostArch),name=iPhone 15,OS=17.0"))
        XCTAssertTrue(simctl.bootCalls.isEmpty)
        XCTAssertTrue(simctl.cloneCalls.isEmpty)
    }

    func testHostTestDoesNotAdoptSimulatorBoundByLaterBuild() throws {
        let (service, _, _) = try fixture()
        try service.recordTest(
            task: task, outcome: .init(success: true, durationSeconds: 1, finishedAt: Date()),
            options: .init(scheme: "MacTests"), resolvedSimulator: nil
        )
        let replay = try service.prepareTestRerun(task: task, overrides: .init())
        XCTAssertTrue(replay.options.noSim)
        XCTAssertNil(try service.resolveSimulator(
            task: task, requestedDevice: replay.options.device, noSim: replay.options.noSim,
            recordedUDID: replay.simulatorUDID
        ))
    }

    func testMissingPriorRunAndMissingFailuresKeepExistingErrors() throws {
        let (service, fs, _) = try fixture()
        XCTAssertThrowsError(try service.prepareTestRerun(
            task: task, overrides: .init(), failedOnly: true, reader: EmptyResults()
        )) { error in
            guard case VibeChardError.testNoPriorFailures = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        var state = try TaskState.parse(fs.readFile(at: workspace.statePath(for: task)))
        state.lastTest = nil
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())
        XCTAssertThrowsError(try service.prepareTestRerun(task: task, overrides: .init())) { error in
            guard case VibeChardError.testNoPriorRun = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRecordsResolvedTestInvocationIndependentlyOfLaterBuild() throws {
        let fs = InMemoryFileSystem()
        var state = TaskState(name: task.raw, branch: "agent/alpha",
                              createdAt: Date(), baseRef: "abc")
        state.setSimulators([.init(cloneUDID: "LAST", sourceUDID: "SOURCE",
                                  name: "iPhone 15-vch-alpha", templateName: "iPhone 15",
                                  runtimeIdentifier: runtime)])
        fs.seedFile(workspace.statePath(for: task), data: try state.jsonData())
        let service = BuildService(workspace: workspace, fs: fs)
        let outcome = BuildOutcome(success: false, durationSeconds: 1, finishedAt: Date())

        try service.recordTest(
            task: task, outcome: outcome,
            options: .init(scheme: "Tests", xcodebuildContainer: .workspace("App.xcworkspace"),
                           configuration: "Release", extraArgs: ["-only-testing:Tests/Suite"]),
            resolvedSimulator: .init(udid: "LAST", name: "iPhone 15-vch-alpha",
                                     createdNow: false, runtime: .init(major: 17, minor: 0))
        )
        try service.recordBuild(task: task, outcome: outcome, scheme: "OtherApp")

        let restored = try TaskState.parse(fs.readFile(at: workspace.statePath(for: task)))
        XCTAssertEqual(restored.scheme, "OtherApp")
        let invocation = try XCTUnwrap(restored.lastTest?.invocation)
        XCTAssertEqual(invocation.scheme, "Tests")
        XCTAssertEqual(invocation.xcodebuildContainer, .workspace("App.xcworkspace"))
        XCTAssertEqual(invocation.configuration, "Release")
        XCTAssertEqual(invocation.device, "iPhone 15")
        XCTAssertEqual(invocation.runtime, "iOS 17.0")
        XCTAssertEqual(invocation.simulatorUDID, "LAST")
        XCTAssertFalse(invocation.noSim)
        XCTAssertEqual(restored.lastTest?.extraArgs, ["-only-testing:Tests/Suite"])
    }
}

private struct FailedResults: XcresultReader {
    func readSummaryJSON(bundlePath: String) throws -> Data {
        Data(#"{"testFailures":[{"testIdentifierString":"Suite/fails()","targetName":"Tests"}]}"#.utf8)
    }
}

private struct EmptyResults: XcresultReader {
    func readSummaryJSON(bundlePath: String) throws -> Data { Data(#"{"testFailures":[]}"#.utf8) }
}
