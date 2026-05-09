import XCTest
@testable import VibeChardCore

final class SimulatorServiceTests: XCTestCase {

    private let mainRepo = "/repos/Demo"

    private func makeService(
        seedingTask raw: String,
        seedingState: TaskState? = nil,
        devices: [SimDevice] = [],
        cloneReturnsUDID: String = "NEW-UDID"
    ) -> (SimulatorService, InMemoryFileSystem, FakeSimctl) {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        let task = try! TaskName(raw)
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedDirectory(workspace.vchDir(for: task))
        if let state = seedingState {
            fs.seedFile(workspace.statePath(for: task), data: try! state.jsonData())
        }
        let simctl = FakeSimctl()
        simctl.devices = devices
        simctl.cloneReturnsUDID = cloneReturnsUDID
        return (SimulatorService(workspace: workspace, simctl: simctl, fs: fs), fs, simctl)
    }

    private func emptyState(_ name: String) -> TaskState {
        TaskState(name: name, branch: "agent/\(name)",
                  createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                  baseRef: "deadbee")
    }

    private func device(_ udid: String, _ name: String, _ runtime: String,
                        _ version: SimRuntimeVersion?,
                        available: Bool = true) -> SimDevice {
        SimDevice(udid: udid, name: name, runtime: runtime,
                  runtimeVersion: version, isAvailable: available)
    }

    // MARK: - newest-template selection

    func testPickNewestTemplatePicksHighestRuntime() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: [
                device("U-OLD", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                       .init(major: 18, minor: 0)),
                device("U-NEW", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
                       .init(major: 18, minor: 2)),
                device("U-OTHER", "iPhone 17",
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                       .init(major: 26, minor: 4)),
            ]
        )
        let pick = try service.pickNewestTemplate(name: "iPhone 16")
        XCTAssertEqual(pick.udid, "U-NEW")
    }

    func testPickNewestTemplateThrowsWhenNoMatch() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: [
                device("U", "iPhone 17",
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                       .init(major: 26, minor: 4)),
            ]
        )
        XCTAssertThrowsError(try service.pickNewestTemplate(name: "iPhone 16")) { err in
            guard case VibeChardError.simulatorTemplateNotFound = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
        }
    }

    func testPickNewestTemplateIgnoresUnavailable() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: [
                device("U-NEW-UNAVAIL", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-19-0",
                       .init(major: 19, minor: 0),
                       available: false),
                device("U-OK", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
                       .init(major: 18, minor: 2)),
            ]
        )
        let pick = try service.pickNewestTemplate(name: "iPhone 16")
        XCTAssertEqual(pick.udid, "U-OK")
    }

    // MARK: - cloneDisplayName

    func testCloneDisplayNameUsesHyphenSuffix() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let name = service.cloneDisplayName(originalName: "iPhone 16",
                                            task: try TaskName("alpha"))
        XCTAssertEqual(name, "iPhone 16-vch-alpha")
    }

    func testStripCloneSuffixHandlesBothSchemes() throws {
        let task = try TaskName("alpha")
        XCTAssertEqual(
            SimulatorService.stripCloneSuffix(
                from: "iPhone 16-vch-alpha", task: task),
            "iPhone 16"
        )
        XCTAssertEqual(
            SimulatorService.stripCloneSuffix(
                from: "iPhone 16 \u{00B7} vch[alpha]", task: task),
            "iPhone 16"
        )
        // No suffix → leave the name alone.
        XCTAssertEqual(
            SimulatorService.stripCloneSuffix(
                from: "iPhone 16", task: task),
            "iPhone 16"
        )
        // Suffix for a different task → leave alone.
        XCTAssertEqual(
            SimulatorService.stripCloneSuffix(
                from: "iPhone 16-vch-beta", task: task),
            "iPhone 16-vch-beta"
        )
    }

    // MARK: - ensureClone

    func testEnsureCloneNoStateFileThrowsCorrupt() throws {
        let (service, _, _) = makeService(seedingTask: "alpha") // no state seeded
        XCTAssertThrowsError(try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16"
        )) { err in
            guard case VibeChardError.stateFileCorrupt = err else {
                return XCTFail("expected stateFileCorrupt, got \(err)")
            }
        }
    }

    func testEnsureCloneReturnsNilWhenNoDeviceAndNoBinding() throws {
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"), requestedDevice: nil
        )
        XCTAssertNil(resolved)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    func testEnsureCloneClonesAndPersistsOnFirstCall() throws {
        let (service, fs, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: [
                device("TPL-NEW", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
                       .init(major: 18, minor: 2)),
            ],
            cloneReturnsUDID: "CLONE-1"
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"), requestedDevice: "iPhone 16"
        )
        XCTAssertEqual(resolved?.udid, "CLONE-1")
        XCTAssertEqual(resolved?.name, "iPhone 16-vch-alpha")
        XCTAssertTrue(resolved?.createdNow ?? false)

        // simctl.clone called exactly once with the right args.
        XCTAssertEqual(simctl.cloneCalls.count, 1)
        XCTAssertEqual(simctl.cloneCalls.first?.source, "TPL-NEW")
        XCTAssertEqual(simctl.cloneCalls.first?.newName, "iPhone 16-vch-alpha")

        // state.json now carries the simulator record.
        let data = try fs.readFile(at: "/repos/Demo-alpha/.vch/state.json")
        let state = try TaskState.parse(data)
        XCTAssertEqual(state.simulator?.cloneUDID, "CLONE-1")
        XCTAssertEqual(state.simulator?.sourceUDID, "TPL-NEW")
        XCTAssertEqual(state.simulator?.name, "iPhone 16-vch-alpha")
        // #4: persist the original template name so subsequent calls
        // with the same `--device` reuse the clone.
        XCTAssertEqual(state.simulator?.templateName, "iPhone 16")
        // #11: persist runtime identifier so `vch state` and the
        // build/test log can surface "iOS X.Y" without a simctl
        // round-trip.
        XCTAssertEqual(state.simulator?.runtimeIdentifier,
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-2")
        XCTAssertEqual(resolved?.runtime, .init(major: 18, minor: 2))
    }

    // #4 regression: a second `vch test foo --device 'iPhone 16'` after
    // the clone was already created must reuse it, not throw.
    func testEnsureCloneReusesWhenDeviceMatchesPersistedTemplate() throws {
        var seed = emptyState("alpha")
        seed.simulator = TaskState.SimulatorRecord(
            cloneUDID: "OLD-CLONE", sourceUDID: "OLD-SRC",
            name: "iPhone 16 · vch[alpha]",
            templateName: "iPhone 16"
        )
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: seed
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"), requestedDevice: "iPhone 16"
        )
        XCTAssertEqual(resolved?.udid, "OLD-CLONE")
        XCTAssertFalse(resolved?.createdNow ?? true)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    // Legacy state (templateName == nil, written by vch ≤ v0.1.x) must
    // still reuse when the user passes the same `--device`.
    func testEnsureCloneReusesLegacyBindingViaSuffixStrip() throws {
        var seed = emptyState("alpha")
        seed.simulator = TaskState.SimulatorRecord(
            cloneUDID: "OLD-CLONE", sourceUDID: "OLD-SRC",
            name: "iPhone 16 · vch[alpha]"
            // templateName intentionally omitted.
        )
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: seed
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"), requestedDevice: "iPhone 16"
        )
        XCTAssertEqual(resolved?.udid, "OLD-CLONE")
        XCTAssertFalse(resolved?.createdNow ?? true)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    // #29: a state.json written by an in-development vch that
    // dropped `templateName` but used the new hyphen suffix must
    // still reuse via suffix-strip.
    func testEnsureCloneReusesHyphenSuffixBindingWithoutTemplateName() throws {
        var seed = emptyState("alpha")
        seed.simulator = TaskState.SimulatorRecord(
            cloneUDID: "OLD-CLONE", sourceUDID: "OLD-SRC",
            name: "iPhone 16-vch-alpha"
            // templateName intentionally omitted.
        )
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: seed
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"), requestedDevice: "iPhone 16"
        )
        XCTAssertEqual(resolved?.udid, "OLD-CLONE")
        XCTAssertFalse(resolved?.createdNow ?? true)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    func testEnsureCloneReusesExistingBinding() throws {
        var seed = emptyState("alpha")
        seed.simulator = TaskState.SimulatorRecord(
            cloneUDID: "OLD-CLONE", sourceUDID: "OLD-SRC",
            name: "iPhone 16 · vch[alpha]"
        )
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: seed
        )
        // No --device, but state already binds.
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"), requestedDevice: nil
        )
        XCTAssertEqual(resolved?.udid, "OLD-CLONE")
        XCTAssertFalse(resolved?.createdNow ?? true)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    func testEnsureCloneRefusesMismatchedDevice() throws {
        var seed = emptyState("alpha")
        seed.simulator = TaskState.SimulatorRecord(
            cloneUDID: "OLD-CLONE", sourceUDID: "OLD-SRC",
            name: "iPhone 16 · vch[alpha]",
            templateName: "iPhone 16"
        )
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: seed
        )
        XCTAssertThrowsError(try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 17 Pro"
        )) { err in
            guard case let VibeChardError.simulatorAlreadyBound(t, current, requested) = err else {
                return XCTFail("expected simulatorAlreadyBound, got \(err)")
            }
            XCTAssertEqual(t, "alpha")
            XCTAssertEqual(current, "iPhone 16 · vch[alpha]")
            XCTAssertEqual(requested, "iPhone 17 Pro")
        }
    }

    // MARK: - delete

    func testDeleteCloneCallsSimctl() throws {
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        try service.deleteClone(udid: "CLONE-1")
        XCTAssertEqual(simctl.deleteCalls, ["CLONE-1"])
    }

    // MARK: - lookupBound (M6)

    func testLookupBoundReturnsNilWhenNoBinding() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let bound = try service.lookupBound(task: try TaskName("alpha"))
        XCTAssertNil(bound)
    }

    func testLookupBoundReturnsRecordWhenBound() throws {
        var seed = emptyState("alpha")
        seed.simulator = TaskState.SimulatorRecord(
            cloneUDID: "C-1", sourceUDID: "S-1",
            name: "iPhone 16 · vch[alpha]"
        )
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: seed
        )
        let bound = try service.lookupBound(task: try TaskName("alpha"))
        XCTAssertEqual(bound?.cloneUDID, "C-1")
        XCTAssertEqual(bound?.sourceUDID, "S-1")
        XCTAssertEqual(bound?.name, "iPhone 16 · vch[alpha]")
    }

    func testLookupBoundThrowsWhenStateMissing() throws {
        let (service, _, _) = makeService(seedingTask: "alpha") // no state
        XCTAssertThrowsError(try service.lookupBound(task: try TaskName("alpha"))) { err in
            guard case VibeChardError.stateFileCorrupt = err else {
                return XCTFail("expected stateFileCorrupt, got \(err)")
            }
        }
    }

    // MARK: - shutdown / erase (M6)

    func testShutdownDelegatesToSimctl() throws {
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        try service.shutdown(udid: "C-1")
        XCTAssertEqual(simctl.shutdownCalls, ["C-1"])
        XCTAssertEqual(simctl.eraseCalls, [])
    }

    func testEraseChainsShutdownThenErase() throws {
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        try service.eraseClone(udid: "C-1")
        XCTAssertEqual(simctl.shutdownCalls, ["C-1"])
        XCTAssertEqual(simctl.eraseCalls, ["C-1"])
    }

    // MARK: - info (M6)

    func testInfoReturnsLiveSimDevice() throws {
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        simctl.devices = [
            SimDevice(udid: "C-1", name: "iPhone 16 · vch[alpha]",
                      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                      runtimeVersion: .init(major: 26, minor: 4),
                      isAvailable: true,
                      state: "Booted"),
        ]
        let live = try service.info(udid: "C-1")
        XCTAssertEqual(live?.udid, "C-1")
        XCTAssertEqual(live?.state, "Booted")
    }

    func testInfoReturnsNilWhenSimctlForgotTheUDID() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let live = try service.info(udid: "GHOST")
        XCTAssertNil(live)
    }

    // MARK: - #11(b) runtime filter

    func testParseRuntimeRequestAcceptsThreeForms() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha", seedingState: emptyState("alpha"))
        let target = SimRuntimeVersion(major: 26, minor: 4)
        XCTAssertEqual(service.parseRuntimeRequest("com.apple.CoreSimulator.SimRuntime.iOS-26-4"), target)
        XCTAssertEqual(service.parseRuntimeRequest("iOS-26-4"), target)
        XCTAssertEqual(service.parseRuntimeRequest("iOS 26.4"), target)
        XCTAssertEqual(service.parseRuntimeRequest("iOS 26"), SimRuntimeVersion(major: 26, minor: 0))
        XCTAssertNil(service.parseRuntimeRequest("garbage"))
    }

    /// #58: `--runtime` accepts the same three forms for any of the
    /// four supported platforms (iOS / watchOS / tvOS / visionOS).
    /// visionOS additionally accepts both `visionOS` (user-friendly)
    /// and `xrOS` (CoreSimulator slug) prefixes — simctl emits the
    /// latter in `runtime` identifiers but the former in human labels,
    /// and users copy-paste from both surfaces.
    func testParseRuntimeRequestAcceptsAllFourPlatforms() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha", seedingState: emptyState("alpha"))

        // iOS — covered by the previous test, kept here for parity.
        XCTAssertEqual(service.parseRuntimeRequest("iOS 26.4"),
                       SimRuntimeVersion(platform: .iOS, major: 26, minor: 4))

        // watchOS
        let watchTarget = SimRuntimeVersion(platform: .watchOS, major: 11, minor: 5)
        XCTAssertEqual(service.parseRuntimeRequest("com.apple.CoreSimulator.SimRuntime.watchOS-11-5"), watchTarget)
        XCTAssertEqual(service.parseRuntimeRequest("watchOS-11-5"), watchTarget)
        XCTAssertEqual(service.parseRuntimeRequest("watchOS 11.5"), watchTarget)

        // tvOS
        let tvTarget = SimRuntimeVersion(platform: .tvOS, major: 18, minor: 0)
        XCTAssertEqual(service.parseRuntimeRequest("com.apple.CoreSimulator.SimRuntime.tvOS-18-0"), tvTarget)
        XCTAssertEqual(service.parseRuntimeRequest("tvOS-18-0"), tvTarget)
        XCTAssertEqual(service.parseRuntimeRequest("tvOS 18.0"), tvTarget)

        // visionOS — both `xrOS` and `visionOS` prefixes accepted.
        let visionTarget = SimRuntimeVersion(platform: .visionOS, major: 2, minor: 5)
        XCTAssertEqual(service.parseRuntimeRequest("com.apple.CoreSimulator.SimRuntime.xrOS-2-5"), visionTarget)
        XCTAssertEqual(service.parseRuntimeRequest("xrOS-2-5"), visionTarget)
        XCTAssertEqual(service.parseRuntimeRequest("visionOS-2-5"), visionTarget)
        XCTAssertEqual(service.parseRuntimeRequest("visionOS 2.5"), visionTarget)
        XCTAssertEqual(service.parseRuntimeRequest("xrOS 2.5"), visionTarget)

        // Case-insensitive prefix matching for usability.
        XCTAssertEqual(service.parseRuntimeRequest("ios 26.4"),
                       SimRuntimeVersion(platform: .iOS, major: 26, minor: 4))
        XCTAssertEqual(service.parseRuntimeRequest("WATCHOS-11-5"), watchTarget)

        // macOS / unknown platforms still reject.
        XCTAssertNil(service.parseRuntimeRequest("macOS 14.0"))
        XCTAssertNil(service.parseRuntimeRequest("garbage"))
    }

    func testPickNewestTemplateFiltersByRuntime() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha", seedingState: emptyState("alpha"),
            devices: [
                device("U-OLD", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
                       .init(major: 18, minor: 5)),
                device("U-NEW", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                       .init(major: 26, minor: 4)),
            ]
        )
        let pinned = try service.pickNewestTemplate(name: "iPhone 16",
                                                     requestedRuntime: "iOS 18.5")
        XCTAssertEqual(pinned.udid, "U-OLD") // honored, not silently picked newest
    }

    func testPickNewestTemplateRuntimeMissThrowsWithAvailableList() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha", seedingState: emptyState("alpha"),
            devices: [
                device("U", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                       .init(major: 26, minor: 4)),
            ]
        )
        XCTAssertThrowsError(
            try service.pickNewestTemplate(name: "iPhone 16",
                                           requestedRuntime: "iOS 18.5")
        ) { err in
            guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
            XCTAssertTrue(name.contains("iOS 26.4"),
                          "should list installed runtimes; got: \(name)")
        }
    }

    /// #58: when `pickNewestTemplate` reports the available runtimes
    /// to the user, visionOS devices must be surfaced with the
    /// human-friendly "visionOS X.Y" label, **not** the internal
    /// CoreSimulator "xrOS X.Y" slug. The two strings denote the same
    /// runtime but only one is what the user typed and what
    /// `--runtime` accepts on subsequent invocations — getting this
    /// wrong would tell the user to copy-paste a value that the CLI
    /// then rejects. This locks the dottedLabel formatting on the
    /// error path for the visionOS-vs-xrOS asymmetry specifically.
    func testPickNewestTemplateRuntimeMissShowsHumanLabelsForVisionOS() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha", seedingState: emptyState("alpha"),
            devices: [
                device("V", "Apple Vision Pro",
                       "com.apple.CoreSimulator.SimRuntime.xrOS-2-5",
                       .init(platform: .visionOS, major: 2, minor: 5)),
            ]
        )
        XCTAssertThrowsError(
            try service.pickNewestTemplate(name: "Apple Vision Pro",
                                           requestedRuntime: "visionOS 1.0")
        ) { err in
            guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
            XCTAssertTrue(name.contains("visionOS 2.5"),
                          "should surface human label, got: \(name)")
            XCTAssertFalse(name.contains("xrOS 2.5"),
                           "must not leak CoreSimulator slug, got: \(name)")
        }
    }

    func testEnsureCloneRefusesReuseOnRuntimeMismatch() throws {
        let bound = TaskState.SimulatorRecord(
            cloneUDID: "C", sourceUDID: "TPL", name: "iPhone 16 · vch[alpha]",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
        )
        var state = emptyState("alpha")
        state.simulator = bound
        let (service, _, _) = makeService(
            seedingTask: "alpha", seedingState: state)
        XCTAssertThrowsError(
            try service.ensureClone(task: try TaskName("alpha"),
                                    requestedDevice: "iPhone 16",
                                    requestedRuntime: "iOS 26.4")
        ) { err in
            guard case let VibeChardError.simulatorAlreadyBound(_, currentName, requestedName) = err else {
                return XCTFail("expected simulatorAlreadyBound, got \(err)")
            }
            XCTAssertTrue(currentName.contains("iOS 18.5"))
            XCTAssertTrue(requestedName.contains("iOS 26.4"))
        }
    }
}

// MARK: - test double

final class FakeSimctl: SimctlClient, @unchecked Sendable {
    var devices: [SimDevice] = []
    /// Used by `allDevices()`. Defaults to `devices` (so existing tests
    /// don't have to set both); set explicitly when you need them to
    /// differ (e.g. simulating an unavailable runtime).
    var allDevicesOverride: [SimDevice]?
    var cloneReturnsUDID: String = ""
    /// Returned by `create()`. Tests that exercise warm-template
    /// creation (#47) set this to the synthetic UDID they want.
    var createReturnsUDID: String = ""
    var bootCalls: [String] = []
    var deleteCalls: [String] = []
    var shutdownCalls: [String] = []
    var eraseCalls: [String] = []
    var cloneCalls: [(source: String, newName: String)] = []
    var createCalls: [(name: String, deviceTypeID: String, runtimeID: String)] = []
    var installCalls: [(udid: String, appPath: String)] = []
    var launchCalls: [(udid: String, bundleID: String, args: [String])] = []
    var availableThrows: VibeChardError?
    var allThrows: VibeChardError?
    var cloneThrows: VibeChardError?
    var createThrows: VibeChardError?
    var bootThrows: VibeChardError?
    var shutdownThrows: VibeChardError?
    var eraseThrows: VibeChardError?
    var deleteThrows: VibeChardError?
    var installThrows: VibeChardError?
    var launchThrows: VibeChardError?

    func availableDevices() throws -> [SimDevice] {
        if let err = availableThrows { throw err }
        return devices
    }

    func allDevices() throws -> [SimDevice] {
        if let err = allThrows { throw err }
        return allDevicesOverride ?? devices
    }

    func clone(sourceUDID: String, newName: String) throws -> String {
        if let err = cloneThrows { throw err }
        cloneCalls.append((sourceUDID, newName))
        return cloneReturnsUDID
    }

    func create(name: String, deviceTypeID: String, runtimeID: String) throws -> String {
        if let err = createThrows { throw err }
        createCalls.append((name, deviceTypeID, runtimeID))
        return createReturnsUDID
    }

    func bootstatusBoot(udid: String) throws {
        if let err = bootThrows { throw err }
        bootCalls.append(udid)
    }

    func shutdown(udid: String) throws {
        if let err = shutdownThrows { throw err }
        shutdownCalls.append(udid)
    }

    func erase(udid: String) throws {
        if let err = eraseThrows { throw err }
        eraseCalls.append(udid)
    }

    func delete(udid: String) throws {
        if let err = deleteThrows { throw err }
        deleteCalls.append(udid)
    }

    func install(udid: String, appPath: String) throws {
        if let err = installThrows { throw err }
        installCalls.append((udid, appPath))
    }

    func launch(udid: String, bundleID: String, args: [String]) throws {
        if let err = launchThrows { throw err }
        launchCalls.append((udid, bundleID, args))
    }
}
