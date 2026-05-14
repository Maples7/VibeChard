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
        if let state = seedingState, !state.allSimulators.isEmpty {
            simctl.allDevicesOverride = devices + state.allSimulators.map { record in
                SimDevice(
                    udid: record.cloneUDID,
                    name: record.name,
                    runtime: record.runtimeIdentifier ?? "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                    runtimeVersion: record.runtimeVersion,
                    isAvailable: true,
                    state: "Shutdown"
                )
            }
        }
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

    func testEnsureCloneAppendsBindingForDifferentDevice() throws {
        // #99: when a task already has one binding and the caller
        // passes a *different* `--device`, ensureClone now clones a
        // second binding and appends it to `state.simulators` rather
        // than throwing `simulatorAlreadyBound`. That's the whole
        // point of the multi-platform feature — an iOS task can
        // grow a watchOS sibling without removing the task first.
        var seed = emptyState("alpha")
        seed.simulator = TaskState.SimulatorRecord(
            cloneUDID: "OLD-CLONE", sourceUDID: "OLD-SRC",
            name: "iPhone 16 · vch[alpha]",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
        )
        let (service, fs, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: seed,
            devices: [
                device("WATCH-TPL", "Apple Watch Series 10 (46mm)",
                       "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
                       .init(platform: .watchOS, major: 11, minor: 0)),
            ],
            cloneReturnsUDID: "NEW-WATCH-CLONE"
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "Apple Watch Series 10 (46mm)"
        )
        XCTAssertEqual(resolved?.udid, "NEW-WATCH-CLONE")
        XCTAssertTrue(resolved?.createdNow ?? false,
                      "ensureClone must report the new binding as freshly created")
        XCTAssertEqual(simctl.cloneCalls.count, 1,
                       "exactly one simctl clone for the second platform binding")

        // Persisted state should now carry BOTH bindings.
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let task = try TaskName("alpha")
        let stateData = try fs.readFile(at: workspace.statePath(for: task))
        let state = try TaskState.parse(stateData)
        XCTAssertEqual(state.allSimulators.count, 2)
        XCTAssertEqual(state.allSimulators[0].cloneUDID, "OLD-CLONE")
        XCTAssertEqual(state.allSimulators[1].cloneUDID, "NEW-WATCH-CLONE")
        XCTAssertEqual(state.allSimulators[1].templateName,
                       "Apple Watch Series 10 (46mm)")
        // Legacy `simulator` field mirrors the FIRST binding for
        // downgrade safety.
        XCTAssertEqual(state.simulator?.cloneUDID, "OLD-CLONE")
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

    // MARK: - lookupBound under adopted worktree (#98 follow-up)

    /// `lookupBound` reads `state.json` from
    /// `workspace.statePath(for:)`. For an adopted task this means
    /// reading from `<adoptedPath>/.vch/state.json`. If the override
    /// were ever bypassed, lookupBound would either return nil (state
    /// not seeded at the wrong location) or throw stateFileCorrupt
    /// — both observable failures of `vch sim list` against an
    /// adopted task.
    func testLookupBoundReadsFromAdoptedWorktreeStatePath() throws {
        let adoptedPath = "/Users/me/codex-session"
        let task = try TaskName("codex-task")
        let workspace = Workspace(mainWorktreePath: mainRepo)
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(adoptedPath)
        fs.seedDirectory("\(adoptedPath)/.vch")
        var state = TaskState(
            name: "codex-task",
            branch: "feature/codex",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbee",
            worktreeOwnership: .adopted
        )
        state.simulator = TaskState.SimulatorRecord(
            cloneUDID: "C-9", sourceUDID: "S-9",
            name: "iPhone 16 · vch[codex-task]"
        )
        fs.seedFile(workspace.statePath(for: task),
                    data: try state.jsonData())
        let simctl = FakeSimctl()
        simctl.allDevicesOverride = [
            SimDevice(udid: "C-9", name: "iPhone 16 · vch[codex-task]",
                      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                      runtimeVersion: .init(major: 26, minor: 4),
                      isAvailable: true),
        ]
        let service = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)

        let bound = try service.lookupBound(task: task)
        XCTAssertEqual(bound?.cloneUDID, "C-9")
        XCTAssertEqual(bound?.sourceUDID, "S-9")
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

    func testEnsureCloneAppendsBindingForRuntimeMismatch() throws {
        // #99: when a single iPhone 16 binding exists on iOS 18.5 and
        // the caller asks for `--device "iPhone 16" --runtime
        // "iOS 26.4"`, the filter excludes the iOS-18.5 record (its
        // runtime differs), so ensureClone clones a NEW iPhone 16
        // binding pinned to iOS 26.4 and appends it. This replaces
        // the pre-#99 "simulatorAlreadyBound" hard-fail.
        let bound = TaskState.SimulatorRecord(
            cloneUDID: "C-18", sourceUDID: "TPL-18",
            name: "iPhone 16 · vch[alpha]",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
        )
        var state = emptyState("alpha")
        state.simulator = bound
        let (service, fs, simctl) = makeService(
            seedingTask: "alpha", seedingState: state,
            devices: [
                device("TPL-26", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                       .init(major: 26, minor: 4)),
            ],
            cloneReturnsUDID: "C-26"
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16",
            requestedRuntime: "iOS 26.4"
        )
        XCTAssertEqual(resolved?.udid, "C-26")
        XCTAssertTrue(resolved?.createdNow ?? false)
        XCTAssertEqual(simctl.cloneCalls.count, 1)

        let workspace = Workspace(mainWorktreePath: mainRepo)
        let task = try TaskName("alpha")
        let after = try TaskState.parse(try fs.readFile(at: workspace.statePath(for: task)))
        XCTAssertEqual(after.allSimulators.count, 2)
        XCTAssertEqual(after.allSimulators[0].runtimeIdentifier,
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-5")
        XCTAssertEqual(after.allSimulators[1].runtimeIdentifier,
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
    }

    func testEnsureCloneRefusesSingleBindingReuseWhenRuntimePinned() throws {
        // Pre-#99 single-binding reuse path: when the caller does NOT
        // pass `--device` (just `--runtime`) and the only binding's
        // runtime disagrees, ensureClone still throws
        // `simulatorAlreadyBound`. This preserves the actionable
        // legacy message for "I forgot to also pass --device" users.
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
                                    requestedDevice: nil,
                                    requestedRuntime: "iOS 26.4")
        ) { err in
            guard case let VibeChardError.simulatorAlreadyBound(_, currentName, requestedName) = err else {
                return XCTFail("expected simulatorAlreadyBound, got \(err)")
            }
            XCTAssertTrue(currentName.contains("iOS 18.5"))
            XCTAssertTrue(requestedName.contains("iOS 26.4"))
        }
    }

    // MARK: - #66: simctl clone refuses booted templates

    /// `simctl clone` returns "Unable to clone device in current state:
    /// Booted" with a non-zero exit when the source template is
    /// running. By default vch must lift that into a typed
    /// `simulatorTemplateBooted` error so callers (and the user) get
    /// an actionable message and an opt-in flag — not a raw
    /// `externalCommandFailed` blob.
    func testEnsureCloneRaisesTypedErrorWhenTemplateIsBooted() throws {
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: [
                device("TPL-BOOTED", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
                       .init(major: 18, minor: 2)),
            ]
        )
        simctl.cloneThrows = .externalCommandFailed(
            cmd: "xcrun simctl clone TPL-BOOTED iPhone 16-vch-alpha",
            exitCode: 149,
            stderr: "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError.149, code=149):\nUnable to clone device in current state: Booted"
        )

        XCTAssertThrowsError(
            try service.ensureClone(
                task: try TaskName("alpha"),
                requestedDevice: "iPhone 16"
            )
        ) { err in
            guard case let VibeChardError.simulatorTemplateBooted(name, udid) = err else {
                return XCTFail("expected simulatorTemplateBooted, got \(err)")
            }
            XCTAssertEqual(name, "iPhone 16")
            XCTAssertEqual(udid, "TPL-BOOTED")
        }
        // We must NOT have shut anything down without opt-in: the
        // template is shared across tasks (hard rule #9). The user
        // sees the typed error and decides.
        XCTAssertEqual(simctl.shutdownCalls, [])
    }

    /// With `shutdownTemplate: true`, vch shuts the template down and
    /// retries the clone. Modelled with a `FakeSimctl` subclass that
    /// drops `cloneThrows` from the `shutdown(udid:)` side-effect, so
    /// the second `clone` call succeeds.
    func testEnsureCloneRetriesAfterShutdownWhenOptIn() throws {
        final class OneShotShutdownFake: FakeSimctl, @unchecked Sendable {
            override func shutdown(udid: String) throws {
                cloneThrows = nil
                try super.shutdown(udid: udid)
            }
        }

        let oneShot = OneShotShutdownFake()
        oneShot.devices = [
            device("TPL-BOOTED", "iPhone 16",
                   "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
                   .init(major: 18, minor: 2)),
        ]
        oneShot.cloneReturnsUDID = "CLONE-RETRY"
        oneShot.cloneThrows = .externalCommandFailed(
            cmd: "xcrun simctl clone TPL-BOOTED iPhone 16-vch-alpha",
            exitCode: 149,
            stderr: "Unable to clone device in current state: Booted"
        )

        let workspace = Workspace(mainWorktreePath: mainRepo)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        let task = try TaskName("alpha")
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedDirectory(workspace.vchDir(for: task))
        fs.seedFile(workspace.statePath(for: task),
                    data: try emptyState("alpha").jsonData())
        let svc = SimulatorService(workspace: workspace, simctl: oneShot, fs: fs)

        let resolved = try svc.ensureClone(
            task: task,
            requestedDevice: "iPhone 16",
            shutdownTemplate: true
        )
        XCTAssertEqual(resolved?.udid, "CLONE-RETRY")
        // Exactly one shutdown call, on the *template* UDID — not the
        // clone's (which doesn't exist yet at the time we shut down).
        XCTAssertEqual(oneShot.shutdownCalls, ["TPL-BOOTED"])
        // FakeSimctl.clone throws *before* appending to cloneCalls, so
        // the first failing attempt isn't recorded — only the
        // post-shutdown retry is. The shutdown call above is the
        // proof that the retry path actually fired.
        XCTAssertEqual(oneShot.cloneCalls.count, 1)
        XCTAssertEqual(oneShot.cloneCalls.first?.source, "TPL-BOOTED")
        XCTAssertEqual(oneShot.cloneCalls.first?.newName, "iPhone 16-vch-alpha")
    }

    /// A clone failure that is NOT the booted-template message is left
    /// alone — we only branch on the exact substring, every other
    /// failure mode keeps the raw `externalCommandFailed` envelope.
    func testEnsureCloneDoesNotRewriteUnrelatedCloneFailures() throws {
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: [
                device("TPL-NEW", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
                       .init(major: 18, minor: 2)),
            ]
        )
        simctl.cloneThrows = .externalCommandFailed(
            cmd: "xcrun simctl clone TPL-NEW iPhone 16-vch-alpha",
            exitCode: 1,
            stderr: "Some unrelated failure that has nothing to do with Booted templates"
        )
        XCTAssertThrowsError(
            try service.ensureClone(
                task: try TaskName("alpha"),
                requestedDevice: "iPhone 16",
                shutdownTemplate: true   // would still NOT trigger the retry path
            )
        ) { err in
            guard case VibeChardError.externalCommandFailed = err else {
                return XCTFail("expected externalCommandFailed, got \(err)")
            }
        }
        XCTAssertEqual(simctl.shutdownCalls, [])
    }

    // MARK: - #99 multi-platform bindings

    /// Helper: seed two bindings (iOS + watchOS) on `alpha` and
    /// return a configured service that knows about templates for
    /// both platforms plus an iOS 26.4 template (used by ambiguity
    /// tests that need a same-device-different-runtime case).
    private func makeServiceWithTwoBindings(
        cloneReturnsUDID: String = "NEW-UDID"
    ) -> (SimulatorService, InMemoryFileSystem, FakeSimctl) {
        var seed = emptyState("alpha")
        seed.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "IOS-CLONE", sourceUDID: "IOS-TPL",
                name: "iPhone 16-vch-alpha",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
            ),
            TaskState.SimulatorRecord(
                cloneUDID: "WATCH-CLONE", sourceUDID: "WATCH-TPL",
                name: "Apple Watch Series 10-vch-alpha",
                templateName: "Apple Watch Series 10 (46mm)",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"
            ),
        ])
        return makeService(
            seedingTask: "alpha",
            seedingState: seed,
            devices: [
                device("IOS-26-TPL", "iPhone 16",
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                       .init(major: 26, minor: 4)),
            ],
            cloneReturnsUDID: cloneReturnsUDID
        )
    }

    func testEnsureCloneReusesIOSBindingWhenDeviceMatches() throws {
        // Two bindings (iOS + watchOS) + `--device "iPhone 16"`:
        // filter narrows to the iOS binding, reuse it, no new clone.
        let (service, _, simctl) = makeServiceWithTwoBindings()
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16"
        )
        XCTAssertEqual(resolved?.udid, "IOS-CLONE")
        XCTAssertFalse(resolved?.createdNow ?? true)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    func testEnsureCloneThrowsAmbiguousWhenMultipleBindingsAndNoDevice() throws {
        // Two bindings + no `--device`: ensureClone can't pick for
        // the user, so it raises `simulatorBindingAmbiguous` (and
        // ExitCode maps it to business=1). The previous single-binding
        // implicit-reuse path is intentionally gone for multi-binding
        // tasks — silently picking would be surprising.
        let (service, _, _) = makeServiceWithTwoBindings()
        XCTAssertThrowsError(try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: nil
        )) { err in
            guard case let VibeChardError.simulatorBindingAmbiguous(t, candidates) = err else {
                return XCTFail("expected simulatorBindingAmbiguous, got \(err)")
            }
            XCTAssertEqual(t, "alpha")
            XCTAssertEqual(candidates.count, 2)
            XCTAssertTrue(candidates.contains("iPhone 16-vch-alpha"))
            XCTAssertTrue(candidates.contains("Apple Watch Series 10-vch-alpha"))
        }
    }

    func testEnsureCloneUsesRequestedPlatformWhenNoDevice() throws {
        // The build/test path can infer the scheme platform. With two
        // bindings it should use that to pick the matching platform
        // instead of requiring --device.
        let (service, _, simctl) = makeServiceWithTwoBindings()
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: nil,
            requestedPlatform: .watchOS
        )
        XCTAssertEqual(resolved?.udid, "WATCH-CLONE")
        XCTAssertEqual(resolved?.platform, .watchOS)
        XCTAssertEqual(simctl.cloneCalls.count, 0)
    }

    func testEnsureClonePrunesStaleBindingBeforePlatformAmbiguity() throws {
        // #111: if one of the stored watchOS bindings was deleted
        // directly with simctl, it must not keep participating in
        // the build/test ambiguity check. The remaining live binding
        // should be reused and state.json should be compacted.
        var seed = emptyState("alpha")
        seed.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "WATCH-LIVE", sourceUDID: "WATCH-TPL-1",
                name: "BeanLedger Template Watch S11 26.5-vch-alpha",
                templateName: "BeanLedger Template Watch S11 26.5",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-5"
            ),
            TaskState.SimulatorRecord(
                cloneUDID: "WATCH-GONE", sourceUDID: "WATCH-TPL-2",
                name: "Apple Watch Series 11 (46mm)-vch-alpha",
                templateName: "Apple Watch Series 11 (46mm)",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-5"
            ),
        ])
        let (service, fs, simctl) = makeService(seedingTask: "alpha", seedingState: seed)
        simctl.allDevicesOverride = [
            device("WATCH-LIVE", "BeanLedger Template Watch S11 26.5-vch-alpha",
                   "com.apple.CoreSimulator.SimRuntime.watchOS-26-5",
                   .init(platform: .watchOS, major: 26, minor: 5)),
        ]

        let resolved = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: nil,
            requestedPlatform: .watchOS
        )

        XCTAssertEqual(resolved?.udid, "WATCH-LIVE")
        XCTAssertFalse(resolved?.createdNow ?? true)
        XCTAssertEqual(simctl.cloneCalls.count, 0)

        let workspace = Workspace(mainWorktreePath: mainRepo)
        let after = try TaskState.parse(
            try fs.readFile(at: workspace.statePath(for: try TaskName("alpha")))
        )
        XCTAssertEqual(after.allSimulators.map(\.cloneUDID), ["WATCH-LIVE"])
        XCTAssertEqual(after.simulator?.cloneUDID, "WATCH-LIVE")
    }

    func testEnsureCloneRejectsSingleBindingFromWrongPlatform() throws {
        // Regression for #102: after a task has only a watchOS binding,
        // a later iOS scheme with no --device must not silently reuse
        // that watch UDID.
        var seed = emptyState("alpha")
        seed.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "WATCH-CLONE",
                sourceUDID: "WATCH-TPL",
                name: "Apple Watch Series 10-vch-alpha",
                templateName: "Apple Watch Series 10 (46mm)",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"
            ),
        ])
        let (service, _, _) = makeService(seedingTask: "alpha", seedingState: seed)
        XCTAssertThrowsError(try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: nil,
            requestedPlatform: .iOS
        )) { err in
            guard case let VibeChardError.simulatorBindingPlatformUnavailable(task, platform, candidates) = err else {
                return XCTFail("expected simulatorBindingPlatformUnavailable, got \(err)")
            }
            XCTAssertEqual(task, "alpha")
            XCTAssertEqual(platform, "iOS Simulator")
            XCTAssertEqual(candidates, ["Apple Watch Series 10-vch-alpha"])
        }
    }

    func testEnsureCloneAmbiguousWhenTwoBindingsSameDeviceAndNoRuntime() throws {
        // Same device on two runtimes (iOS 18.2 + iOS 26.4) + caller
        // passes `--device "iPhone 16"` only. Filter narrows to 2
        // candidates → ambiguous. The actionable message tells the
        // user to add `--runtime`.
        var seed = emptyState("alpha")
        seed.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "C-18", sourceUDID: "TPL-18",
                name: "iPhone 16-vch-alpha",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
            ),
            TaskState.SimulatorRecord(
                cloneUDID: "C-26", sourceUDID: "TPL-26",
                name: "iPhone 16-vch-alpha-2",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
            ),
        ])
        let (service, _, _) = makeService(seedingTask: "alpha", seedingState: seed)
        XCTAssertThrowsError(try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16"
        )) { err in
            guard case let VibeChardError.simulatorBindingAmbiguous(_, candidates) = err else {
                return XCTFail("expected simulatorBindingAmbiguous, got \(err)")
            }
            XCTAssertEqual(candidates.count, 2)
        }
    }

    func testEnsureCloneRoundtripsLegacyStateAsSingleBinding() throws {
        // Pre-#99 state.json populated only `simulator` (no
        // `simulators` list). The `allSimulators` accessor promotes
        // it into a one-element list, so every code path that
        // iterates bindings (reuse, lookup, info, rm) Just Works
        // without a schema bump or a migration write.
        var seed = emptyState("alpha")
        seed.simulator = TaskState.SimulatorRecord(
            cloneUDID: "LEGACY-CLONE", sourceUDID: "TPL",
            name: "iPhone 16-vch-alpha",
            templateName: "iPhone 16"
        )
        seed.simulators = nil   // explicit: legacy schema, no list field.
        let (service, _, simctl) = makeService(
            seedingTask: "alpha", seedingState: seed)
        // No `--device`, single binding → silent reuse.
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"), requestedDevice: nil)
        XCTAssertEqual(resolved?.udid, "LEGACY-CLONE")
        XCTAssertEqual(simctl.cloneCalls.count, 0)

        let all = try service.lookupAllBindings(task: try TaskName("alpha"))
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].cloneUDID, "LEGACY-CLONE")
    }

    func testLookupBoundThrowsAmbiguousOnMultipleBindings() throws {
        // The `lookupBound` shorthand only makes sense when there are
        // 0 or 1 bindings. With ≥2 it raises the same ambiguous
        // error as ensureClone, forcing callers to explicitly route
        // through `lookupAllBindings` or `resolveBindingForCLI`.
        let (service, _, _) = makeServiceWithTwoBindings()
        XCTAssertThrowsError(try service.lookupBound(task: try TaskName("alpha"))) { err in
            guard case VibeChardError.simulatorBindingAmbiguous = err else {
                return XCTFail("expected simulatorBindingAmbiguous, got \(err)")
            }
        }
    }

    func testResolveBindingForCLIDevicePicksOne() throws {
        let (service, _, _) = makeServiceWithTwoBindings()
        let bound = try service.resolveBindingForCLI(
            task: try TaskName("alpha"),
            device: "Apple Watch Series 10 (46mm)",
            runtime: nil
        )
        XCTAssertEqual(bound?.cloneUDID, "WATCH-CLONE")
    }

    func testResolveBindingForCLIWithoutSelectorThrowsAmbiguous() throws {
        let (service, _, _) = makeServiceWithTwoBindings()
        XCTAssertThrowsError(try service.resolveBindingForCLI(
            task: try TaskName("alpha"), device: nil, runtime: nil
        )) { err in
            guard case VibeChardError.simulatorBindingAmbiguous = err else {
                return XCTFail("expected simulatorBindingAmbiguous, got \(err)")
            }
        }
    }

    func testResolveBindingForCLIRuntimeDisambiguates() throws {
        // Two bindings share a device but pin different runtimes.
        // `--device "iPhone 16" --runtime "iOS 26.4"` resolves to one.
        var seed = emptyState("alpha")
        seed.setSimulators([
            TaskState.SimulatorRecord(
                cloneUDID: "C-18", sourceUDID: "TPL-18",
                name: "iPhone 16-vch-alpha",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
            ),
            TaskState.SimulatorRecord(
                cloneUDID: "C-26", sourceUDID: "TPL-26",
                name: "iPhone 16-vch-alpha-2",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
            ),
        ])
        let (service, _, _) = makeService(seedingTask: "alpha", seedingState: seed)
        let bound = try service.resolveBindingForCLI(
            task: try TaskName("alpha"),
            device: "iPhone 16",
            runtime: "iOS 26.4"
        )
        XCTAssertEqual(bound?.cloneUDID, "C-26")
    }

    // MARK: - auto-create base device (#110)

    func testPickNewestTemplateAutoCreatesBaseDeviceWhenMissing() throws {
        // No device with name "iPhone 17" exists, but the user passes
        // --device "iPhone 17" --runtime "iOS 26.5". pickNewestTemplate
        // should auto-create a base device for that combination.
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: [],  // No existing devices
            cloneReturnsUDID: "NEW-BASE-UDID"
        )
        simctl.createReturnsUDID = "NEW-BASE-UDID"

        let pick = try service.pickNewestTemplate(
            name: "iPhone 17",
            requestedRuntime: "iOS 26.5"
        )
        XCTAssertEqual(pick.udid, "NEW-BASE-UDID")
        XCTAssertEqual(pick.name, "iPhone 17")
        XCTAssertEqual(pick.isAvailable, true)
        XCTAssertEqual(pick.state, "Shutdown")
        XCTAssertTrue(pick.runtime.contains("iOS-26-5"), "runtime identifier should match requested runtime")
        XCTAssertEqual(pick.runtimeVersion?.platform, .iOS, "platform should be iOS")
        XCTAssertEqual(pick.runtimeVersion?.major, 26, "major version should be 26")
        XCTAssertEqual(pick.runtimeVersion?.minor, 5, "minor version should be 5")
        XCTAssertEqual(simctl.createCalls.count, 1)
        let call = simctl.createCalls[0]
        XCTAssertEqual(call.name, "iPhone 17")
        XCTAssertEqual(call.deviceTypeID, "iPhone 17")
        XCTAssertTrue(call.runtimeID.contains("iOS-26-5"))
    }

    func testPickNewestTemplateThrowsWhenAutoCreateFailsNoRuntime() throws {
        // User provides --device but not --runtime. Auto-create
        // requires a runtime, so it should fail with a helpful message.
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: []
        )
        XCTAssertThrowsError(try service.pickNewestTemplate(
            name: "iPhone 17",
            requestedRuntime: nil
        )) { err in
            guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
            XCTAssertTrue(name.contains("no base device"), "error should mention 'no base device', got: \(name)")
            XCTAssertTrue(name.contains("--runtime"), "error should mention '--runtime', got: \(name)")
        }
    }

    func testEnsureCloneSuggestsWatchRuntimeWhenAppleWatchBaseMissing() throws {
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: []
        )
        simctl.runtimes = [
            SimRuntimeVersion(platform: .iOS, major: 26, minor: 5),
            SimRuntimeVersion(platform: .watchOS, major: 26, minor: 5),
        ]

        XCTAssertThrowsError(try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "Apple Watch Series 10 (46mm)",
            requestedRuntime: nil
        )) { err in
            guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
            XCTAssertTrue(
                name.contains("Try: --runtime 'watchOS 26.5'"),
                "Apple Watch missing-template hint should suggest watchOS, got: \(name)"
            )
            XCTAssertFalse(
                name.contains("iOS 26.5"),
                "Apple Watch missing-template hint must not suggest iOS, got: \(name)"
            )
        }
    }

    func testEnsureCloneSuggestsPlatformRuntimeWhenNonIOSBaseMissing() throws {
        let cases: [(device: String, expectedRuntime: String)] = [
            ("Apple TV 4K (3rd generation)", "tvOS 18.0"),
            ("Apple Vision Pro", "visionOS 2.5"),
        ]

        for c in cases {
            let (service, _, simctl) = makeService(
                seedingTask: "alpha",
                seedingState: emptyState("alpha"),
                devices: []
            )
            simctl.runtimes = [
                SimRuntimeVersion(platform: .iOS, major: 26, minor: 5),
                SimRuntimeVersion(platform: .watchOS, major: 26, minor: 5),
                SimRuntimeVersion(platform: .tvOS, major: 18, minor: 0),
                SimRuntimeVersion(platform: .visionOS, major: 2, minor: 5),
            ]

            XCTAssertThrowsError(try service.ensureClone(
                task: try TaskName("alpha"),
                requestedDevice: c.device,
                requestedRuntime: nil
            )) { err in
                guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                    return XCTFail("expected simulatorTemplateNotFound, got \(err)")
                }
                XCTAssertTrue(
                    name.contains("Try: --runtime '\(c.expectedRuntime)'"),
                    "\(c.device) missing-template hint should suggest \(c.expectedRuntime), got: \(name)"
                )
                XCTAssertFalse(
                    name.contains("iOS 26.5"),
                    "\(c.device) missing-template hint must not suggest iOS, got: \(name)"
                )
            }
        }
    }

    func testPickNewestTemplateThrowsWhenAutoCreateFailsInvalidRuntime() throws {
        // User specifies an invalid runtime format.
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: []
        )
        XCTAssertThrowsError(try service.pickNewestTemplate(
            name: "iPhone 17",
            requestedRuntime: "not-a-runtime"
        )) { err in
            guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
            XCTAssertTrue(name.contains("unrecognized runtime"), "error should mention runtime format, got: \(name)")
        }
    }

    func testPickNewestTemplateThrowsWhenAutoCreateFailsDeviceTypeNotInstalled() throws {
        // User specifies a device type that doesn't exist.
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: []
        )
        simctl.createThrows = .externalCommandFailed(
            cmd: "xcrun simctl create",
            exitCode: 1,
            stderr: "Invalid device type: NonexistentDevice"
        )
        XCTAssertThrowsError(try service.pickNewestTemplate(
            name: "NonexistentDevice",
            requestedRuntime: "iOS 26.5"
        )) { err in
            guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
            XCTAssertTrue(name.contains("not installed"), "error should mention device type not installed, got: \(name)")
        }
    }

    func testPickNewestTemplateThrowsWhenAutoCreateFailsRuntimeNotInstalled() throws {
        // Runtime exists but user specified an uninstalled version.
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: []
        )
        simctl.createThrows = .externalCommandFailed(
            cmd: "xcrun simctl create",
            exitCode: 1,
            stderr: "No such runtime: iOS 99.0"
        )
        XCTAssertThrowsError(try service.pickNewestTemplate(
            name: "iPhone 17",
            requestedRuntime: "iOS 99.0"
        )) { err in
            guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
            XCTAssertTrue(name.contains("not installed"), "error should mention runtime not installed, got: \(name)")
        }
    }

    func testPickNewestTemplatePrefersExistingDeviceOverCreating() throws {
        // When a device with the requested name already exists, reuse it
        // instead of auto-creating.
        let (service, _, simctl) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha"),
            devices: [
                device("U-EXIST", "iPhone 17",
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                       .init(platform: .iOS, major: 26, minor: 5)),
            ],
            cloneReturnsUDID: "SHOULD-NOT-CREATE"
        )
        simctl.createReturnsUDID = "SHOULD-NOT-CREATE"

        let pick = try service.pickNewestTemplate(
            name: "iPhone 17",
            requestedRuntime: "iOS 26.5"
        )
        XCTAssertEqual(pick.udid, "U-EXIST")
        XCTAssertEqual(simctl.createCalls.count, 0, "should not create when device exists")
    }

}

// MARK: - test double

class FakeSimctl: SimctlClient, @unchecked Sendable {
    var devices: [SimDevice] = []
    var runtimes: [SimRuntimeVersion] = []
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
    var runtimesThrows: VibeChardError?
    var allThrows: VibeChardError?
    var cloneThrows: VibeChardError?
    var createThrows: VibeChardError?
    var bootThrows: VibeChardError?
    var shutdownThrows: VibeChardError?
    var eraseThrows: VibeChardError?
    var deleteThrows: VibeChardError?
    /// Per-UDID failure mode (#99): used by tests that need a
    /// `simctl.delete` call to fail for SOME bindings but succeed
    /// for others, verifying partial-failure cleanup symmetry in
    /// `LandService` / `RemoveCommand`.
    var deleteThrowsByUDID: [String: VibeChardError] = [:]
    var installThrows: VibeChardError?
    var launchThrows: VibeChardError?

    func availableDevices() throws -> [SimDevice] {
        if let err = availableThrows { throw err }
        return devices
    }

    func availableRuntimes() throws -> [SimRuntimeVersion] {
        if let err = runtimesThrows { throw err }
        return runtimes
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
        if let err = deleteThrowsByUDID[udid] {
            // Record the attempt before bubbling — partial-failure
            // tests want to assert that vch *tried* to delete every
            // binding, even if some throws.
            deleteCalls.append(udid)
            throw err
        }
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
