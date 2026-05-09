import XCTest
@testable import VibeChardCore

/// Tests for `SimulatorService` warm-template surface (#47).
///
/// Covered:
///   * `createWarmTemplate` — happy path, name normalization,
///     runtime ID derivation, refusal to clobber, mid-flight failure
///     cleanup.
///   * `listWarmTemplates` — sorting, health classification.
///   * `removeWarmTemplate` — shutdown-then-delete, normalization,
///     missing-template error.
///   * `pickWarmTemplate` lookup priority in `ensureClone`:
///     warm-template wins when the user pinned a runtime AND a
///     matching healthy warm template exists; falls through to the
///     Apple-template scan otherwise (no runtime / unhealthy / no
///     match).
final class SimulatorServiceWarmTemplateTests: XCTestCase {

    private let mainRepo = "/repos/Demo"

    private func makeService(
        seedingTask raw: String = "alpha",
        seedingState: TaskState? = nil,
        devices: [SimDevice] = [],
        allDevicesOverride: [SimDevice]? = nil,
        cloneReturnsUDID: String = "CLONE-X",
        createReturnsUDID: String = "WARM-NEW"
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
        simctl.allDevicesOverride = allDevicesOverride
        simctl.cloneReturnsUDID = cloneReturnsUDID
        simctl.createReturnsUDID = createReturnsUDID
        return (SimulatorService(workspace: workspace, simctl: simctl, fs: fs), fs, simctl)
    }

    private func emptyState(_ name: String) -> TaskState {
        TaskState(name: name, branch: "agent/\(name)",
                  createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                  baseRef: "deadbee")
    }

    private func device(_ udid: String, _ name: String, _ runtime: String,
                        _ version: SimRuntimeVersion?,
                        state: String? = "Shutdown",
                        available: Bool = true) -> SimDevice {
        SimDevice(udid: udid, name: name, runtime: runtime,
                  runtimeVersion: version, isAvailable: available,
                  state: state)
    }

    // MARK: - createWarmTemplate

    func testCreateWarmTemplateHappyPath() throws {
        let (service, _, simctl) = makeService(
            allDevicesOverride: [],
            createReturnsUDID: "WARM-1"
        )
        let rec = try service.createWarmTemplate(
            deviceName: "iPhone 16", runtimeLabel: "iOS 26.4"
        )
        XCTAssertEqual(rec.name, "vch-warm[iPhone 16:iOS 26.4]")
        XCTAssertEqual(rec.deviceName, "iPhone 16")
        XCTAssertEqual(rec.runtimeLabel, "iOS 26.4")
        XCTAssertEqual(rec.udid, "WARM-1")
        XCTAssertEqual(rec.health, .ok)
        XCTAssertEqual(rec.state, "Shutdown")

        // simctl create called with derived CoreSimulator runtime ID.
        XCTAssertEqual(simctl.createCalls.count, 1)
        XCTAssertEqual(simctl.createCalls.first?.name, "vch-warm[iPhone 16:iOS 26.4]")
        XCTAssertEqual(simctl.createCalls.first?.deviceTypeID, "iPhone 16")
        XCTAssertEqual(simctl.createCalls.first?.runtimeID,
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4")

        // bootstatus then shutdown — primes first-boot caches and
        // leaves the template in static state.
        XCTAssertEqual(simctl.bootCalls, ["WARM-1"])
        XCTAssertEqual(simctl.shutdownCalls, ["WARM-1"])
    }

    func testCreateWarmTemplateNormalizesRuntimeForms() throws {
        // Verbose CoreSimulator runtime ID.
        let (svc1, _, simctl1) = makeService(allDevicesOverride: [],
                                             createReturnsUDID: "U1")
        let rec1 = try svc1.createWarmTemplate(
            deviceName: "iPhone 16",
            runtimeLabel: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
        )
        XCTAssertEqual(rec1.name, "vch-warm[iPhone 16:iOS 26.4]")
        XCTAssertEqual(simctl1.createCalls.first?.runtimeID,
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4")

        // Hyphenated short form.
        let (svc2, _, simctl2) = makeService(allDevicesOverride: [],
                                             createReturnsUDID: "U2")
        let rec2 = try svc2.createWarmTemplate(
            deviceName: "iPhone 16", runtimeLabel: "iOS-18-6"
        )
        XCTAssertEqual(rec2.name, "vch-warm[iPhone 16:iOS 18.6]")
        XCTAssertEqual(simctl2.createCalls.first?.runtimeID,
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-6")
    }

    /// #58: warm-template support extends beyond iOS to watchOS,
    /// tvOS, and visionOS. Exercises the platform-aware code path
    /// from end to end on a non-iOS pair and asserts the canonical
    /// name + CoreSimulator slug. visionOS is also covered to lock
    /// the `xrOS`-vs-`visionOS` translation: name says "visionOS",
    /// runtime ID says "xrOS".
    func testCreateWarmTemplateSupportsAllFourPlatforms() throws {
        // watchOS happy path.
        let (svcW, _, simctlW) = makeService(
            allDevicesOverride: [], createReturnsUDID: "WARM-W"
        )
        let recW = try svcW.createWarmTemplate(
            deviceName: "Apple Watch Series 10 (46mm)",
            runtimeLabel: "watchOS 11.5"
        )
        XCTAssertEqual(recW.name,
                       "vch-warm[Apple Watch Series 10 (46mm):watchOS 11.5]")
        XCTAssertEqual(recW.deviceName, "Apple Watch Series 10 (46mm)")
        XCTAssertEqual(recW.runtimeLabel, "watchOS 11.5")
        XCTAssertEqual(simctlW.createCalls.first?.runtimeID,
                       "com.apple.CoreSimulator.SimRuntime.watchOS-11-5")

        // tvOS happy path.
        let (svcT, _, simctlT) = makeService(
            allDevicesOverride: [], createReturnsUDID: "WARM-T"
        )
        let recT = try svcT.createWarmTemplate(
            deviceName: "Apple TV 4K (3rd generation)",
            runtimeLabel: "tvOS 18.0"
        )
        XCTAssertEqual(recT.name,
                       "vch-warm[Apple TV 4K (3rd generation):tvOS 18.0]")
        XCTAssertEqual(simctlT.createCalls.first?.runtimeID,
                       "com.apple.CoreSimulator.SimRuntime.tvOS-18-0")

        // visionOS — user-facing name uses "visionOS"; the
        // CoreSimulator runtime slug is `xrOS`.
        let (svcV, _, simctlV) = makeService(
            allDevicesOverride: [], createReturnsUDID: "WARM-V"
        )
        let recV = try svcV.createWarmTemplate(
            deviceName: "Apple Vision Pro",
            runtimeLabel: "visionOS 2.5"
        )
        XCTAssertEqual(recV.name, "vch-warm[Apple Vision Pro:visionOS 2.5]")
        XCTAssertEqual(recV.runtimeLabel, "visionOS 2.5")
        XCTAssertEqual(simctlV.createCalls.first?.runtimeID,
                       "com.apple.CoreSimulator.SimRuntime.xrOS-2-5")

        // visionOS via the xrOS prefix (CoreSimulator's identifier
        // surface): canonical name still says "visionOS".
        let (svcV2, _, simctlV2) = makeService(
            allDevicesOverride: [], createReturnsUDID: "WARM-V2"
        )
        let recV2 = try svcV2.createWarmTemplate(
            deviceName: "Apple Vision Pro", runtimeLabel: "xrOS-2-5"
        )
        XCTAssertEqual(recV2.name, "vch-warm[Apple Vision Pro:visionOS 2.5]")
        XCTAssertEqual(simctlV2.createCalls.first?.runtimeID,
                       "com.apple.CoreSimulator.SimRuntime.xrOS-2-5")
    }

    /// Acceptance criterion #7: existing iOS warm-template names
    /// written by vch ≤ v0.3.0 must keep working post-#58. This test
    /// asserts the parser/lookup chain still recognizes the legacy
    /// `vch-warm[iPhone 16:iOS 26.4]` byte sequence and routes it
    /// through `pickWarmTemplate`, with no rename or migration step.
    func testEnsureClonePicksLegacyIOSWarmTemplate() throws {
        let warm = device("WARM-LEGACY", "vch-warm[iPhone 16:iOS 26.4]",
                          "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                          .init(platform: .iOS, major: 26, minor: 4))
        let apple = device("APPLE", "iPhone 16",
                           "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                           .init(platform: .iOS, major: 26, minor: 4))
        let (service, _, simctl) = makeService(
            seedingState: emptyState("alpha"),
            devices: [warm, apple],
            allDevicesOverride: [warm, apple],
            cloneReturnsUDID: "CLONE-FROM-WARM"
        )
        _ = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16",
            requestedRuntime: "iOS 26.4"
        )
        XCTAssertEqual(simctl.cloneCalls.first?.source, "WARM-LEGACY",
                       "legacy iOS warm-template name must still be reused")
    }

    func testCreateWarmTemplateRefusesToClobberExisting() throws {
        let existing = device("EXISTING", "vch-warm[iPhone 16:iOS 26.4]",
                              "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                              .init(major: 26, minor: 4))
        let (service, _, simctl) = makeService(allDevicesOverride: [existing])
        XCTAssertThrowsError(try service.createWarmTemplate(
            deviceName: "iPhone 16", runtimeLabel: "iOS 26.4"
        )) { err in
            guard case let VibeChardError.warmTemplateAlreadyExists(name, udid) = err else {
                return XCTFail("expected warmTemplateAlreadyExists, got \(err)")
            }
            XCTAssertEqual(name, "vch-warm[iPhone 16:iOS 26.4]")
            XCTAssertEqual(udid, "EXISTING")
        }
        // No create / boot / shutdown attempted on the clobber path.
        XCTAssertEqual(simctl.createCalls.count, 0)
        XCTAssertEqual(simctl.bootCalls, [])
    }

    func testCreateWarmTemplateRejectsInvalidRuntime() throws {
        let (service, _, simctl) = makeService(allDevicesOverride: [])
        XCTAssertThrowsError(try service.createWarmTemplate(
            deviceName: "iPhone 16", runtimeLabel: "macOS 14"
        )) { err in
            guard case let VibeChardError.invalidRuntime(label) = err else {
                return XCTFail("expected invalidRuntime, got \(err)")
            }
            XCTAssertEqual(label, "macOS 14")
        }
        XCTAssertEqual(simctl.createCalls.count, 0)
    }

    func testCreateWarmTemplateCleansUpOnBootFailure() throws {
        let (service, _, simctl) = makeService(allDevicesOverride: [],
                                               createReturnsUDID: "WARM-X")
        simctl.bootThrows = .externalCommandFailed(
            cmd: "simctl bootstatus", exitCode: 1, stderr: "boom"
        )
        XCTAssertThrowsError(try service.createWarmTemplate(
            deviceName: "iPhone 16", runtimeLabel: "iOS 26.4"
        ))
        // Best-effort cleanup: shutdown + delete on the half-created
        // device so we don't leave a stuck "Booted" warm template.
        XCTAssertEqual(simctl.shutdownCalls, ["WARM-X"])
        XCTAssertEqual(simctl.deleteCalls, ["WARM-X"])
    }

    /// Cleanup must also run when bootstatus succeeds but the
    /// follow-up `simctl shutdown` fails. Catches the "shutdown threw
    /// after a healthy boot" branch which is otherwise easy to miss
    /// since the catch block calls `try? shutdown` again to swallow
    /// the same error.
    func testCreateWarmTemplateCleansUpOnShutdownFailure() throws {
        let (service, _, simctl) = makeService(allDevicesOverride: [],
                                               createReturnsUDID: "WARM-Y")
        simctl.shutdownThrows = .externalCommandFailed(
            cmd: "simctl shutdown", exitCode: 1, stderr: "stuck"
        )
        XCTAssertThrowsError(try service.createWarmTemplate(
            deviceName: "iPhone 16", runtimeLabel: "iOS 26.4"
        ))
        // boot ran fine; both shutdown attempts (real + cleanup `try?`)
        // hit the fake's throw, but the cleanup `delete` must still
        // fire to avoid leaving a half-primed orphan.
        XCTAssertEqual(simctl.bootCalls, ["WARM-Y"])
        XCTAssertEqual(simctl.deleteCalls, ["WARM-Y"])
    }

    /// Defense-in-depth: empty `--device` value never reaches simctl.
    /// CLI parsing already guards against this in practice, but the
    /// service is also a Core API surface and must validate at its
    /// own boundary.
    func testCreateWarmTemplateRejectsEmptyDeviceName() throws {
        let (service, _, simctl) = makeService(allDevicesOverride: [])
        XCTAssertThrowsError(try service.createWarmTemplate(
            deviceName: "", runtimeLabel: "iOS 26.4"
        )) { err in
            guard case let VibeChardError.missingArgument(field) = err else {
                return XCTFail("expected missingArgument, got \(err)")
            }
            XCTAssertEqual(field, "device name")
        }
        XCTAssertEqual(simctl.createCalls.count, 0)
        XCTAssertEqual(simctl.bootCalls, [])
    }

    // MARK: - listWarmTemplates

    func testListWarmTemplatesIgnoresNonWarmDevices() throws {
        let (service, _, _) = makeService(allDevicesOverride: [
            device("U1", "iPhone 16",
                   "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                   .init(major: 26, minor: 4)),
            device("U2", "iPhone 16-vch-alpha",
                   "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                   .init(major: 26, minor: 4)),
            device("WARM", "vch-warm[iPhone 16:iOS 26.4]",
                   "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                   .init(major: 26, minor: 4)),
        ])
        let rows = try service.listWarmTemplates()
        XCTAssertEqual(rows.map(\.udid), ["WARM"])
    }

    func testListWarmTemplatesClassifiesHealth() throws {
        let (service, _, _) = makeService(allDevicesOverride: [
            device("OK", "vch-warm[iPhone 16:iOS 26.4]",
                   "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                   .init(major: 26, minor: 4)),
            device("STALE", "vch-warm[iPhone 17:iOS 18.0]",
                   "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                   .init(major: 18, minor: 0),
                   available: false),
            device("BOOTED", "vch-warm[iPad Pro:iOS 18.6]",
                   "com.apple.CoreSimulator.SimRuntime.iOS-18-6",
                   .init(major: 18, minor: 6),
                   state: "Booted"),
        ])
        let rows = try service.listWarmTemplates()
        XCTAssertEqual(rows.count, 3)
        // sorted by (deviceName, runtimeLabel) — iPad < iPhone alphabetically.
        XCTAssertEqual(rows[0].udid, "BOOTED")
        XCTAssertEqual(rows[0].health, .booted)
        XCTAssertEqual(rows[1].udid, "OK")
        XCTAssertEqual(rows[1].health, .ok)
        XCTAssertEqual(rows[2].udid, "STALE")
        XCTAssertEqual(rows[2].health, .stale)
    }

    /// Names that pass the `vch-warm[...]` prefix/suffix check but
    /// fail strict parsing (e.g. someone renamed the device through
    /// Xcode and dropped the colon) surface as `Health.malformed`
    /// with empty device/runtime fields. `vch doctor` and the list
    /// command are responsible for showing the warning to the user.
    func testListWarmTemplatesClassifiesMalformed() throws {
        let (service, _, _) = makeService(allDevicesOverride: [
            // Bracketed prefix/suffix but no colon → parse() returns
            // nil → service classifies as malformed.
            device("WEIRD", "vch-warm[no colon inside]",
                   "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                   .init(major: 26, minor: 4)),
        ])
        let rows = try service.listWarmTemplates()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].udid, "WEIRD")
        XCTAssertEqual(rows[0].name, "vch-warm[no colon inside]")
        XCTAssertEqual(rows[0].health, .malformed)
        XCTAssertEqual(rows[0].deviceName, "")
        XCTAssertEqual(rows[0].runtimeLabel, "")
    }

    // MARK: - removeWarmTemplate

    func testRemoveWarmTemplateShutdownsAndDeletes() throws {
        let target = device("TARGET", "vch-warm[iPhone 16:iOS 26.4]",
                            "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                            .init(major: 26, minor: 4))
        let (service, _, simctl) = makeService(allDevicesOverride: [target])
        try service.removeWarmTemplate(deviceName: "iPhone 16",
                                       runtimeLabel: "iOS 26.4")
        XCTAssertEqual(simctl.shutdownCalls, ["TARGET"])
        XCTAssertEqual(simctl.deleteCalls, ["TARGET"])
    }

    func testRemoveWarmTemplateNormalizesRuntime() throws {
        let target = device("TARGET", "vch-warm[iPhone 16:iOS 26.4]",
                            "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                            .init(major: 26, minor: 4))
        let (service, _, simctl) = makeService(allDevicesOverride: [target])
        // Hyphenated input → canonical dotted name still resolves.
        try service.removeWarmTemplate(deviceName: "iPhone 16",
                                       runtimeLabel: "iOS-26-4")
        XCTAssertEqual(simctl.deleteCalls, ["TARGET"])
    }

    func testRemoveWarmTemplateThrowsWhenMissing() throws {
        let (service, _, _) = makeService(allDevicesOverride: [])
        XCTAssertThrowsError(try service.removeWarmTemplate(
            deviceName: "iPhone 16", runtimeLabel: "iOS 26.4"
        )) { err in
            guard case let VibeChardError.simulatorTemplateNotFound(name) = err else {
                return XCTFail("expected simulatorTemplateNotFound, got \(err)")
            }
            XCTAssertEqual(name, "vch-warm[iPhone 16:iOS 26.4]")
        }
    }

    // MARK: - ensureClone integration

    /// Warm template wins over the Apple-template scan when the user
    /// pinned a runtime AND a matching healthy warm template exists.
    func testEnsureClonePicksWarmTemplateOverAppleTemplate() throws {
        let warm = device("WARM", "vch-warm[iPhone 16:iOS 26.4]",
                          "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                          .init(major: 26, minor: 4))
        let apple = device("APPLE", "iPhone 16",
                           "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                           .init(major: 26, minor: 4))
        let (service, fs, simctl) = makeService(
            seedingState: emptyState("alpha"),
            devices: [warm, apple],
            cloneReturnsUDID: "CLONE-FROM-WARM"
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16",
            requestedRuntime: "iOS 26.4"
        )
        XCTAssertEqual(resolved?.udid, "CLONE-FROM-WARM")
        // Cloned from the warm template, not the Apple template.
        XCTAssertEqual(simctl.cloneCalls.first?.source, "WARM")
        // Clone name is per-task (`<requested>-vch-<task>`), NOT
        // derived from the warm-template's `vch-warm[...]` name.
        XCTAssertEqual(simctl.cloneCalls.first?.newName, "iPhone 16-vch-alpha")

        // sourceKind persisted as warm-template, templateName uses
        // the user's `--device` argument so future reuse comparisons
        // match the request, not the warm template's bracketed name.
        let data = try fs.readFile(at: "/repos/Demo-alpha/.vch/state.json")
        let state = try TaskState.parse(data)
        XCTAssertEqual(state.simulator?.templateName, "iPhone 16")
        XCTAssertEqual(state.simulator?.sourceUDID, "WARM")
        XCTAssertEqual(state.simulator?.sourceKind, .warmTemplate)
    }

    /// Without a runtime pin, warm-template lookup is impossible
    /// (different runtimes for the same device = different warm
    /// templates). Falls through to `pickNewestTemplate`.
    func testEnsureCloneSkipsWarmWhenNoRuntimePinned() throws {
        let warm = device("WARM", "vch-warm[iPhone 16:iOS 26.4]",
                          "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                          .init(major: 26, minor: 4))
        let apple = device("APPLE", "iPhone 16",
                           "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                           .init(major: 26, minor: 4))
        let (service, fs, simctl) = makeService(
            seedingState: emptyState("alpha"),
            devices: [warm, apple],
            allDevicesOverride: [warm, apple],
            cloneReturnsUDID: "CLONE-FROM-APPLE"
        )
        let resolved = try service.ensureClone(
            task: try TaskName("alpha"), requestedDevice: "iPhone 16"
        )
        XCTAssertEqual(resolved?.udid, "CLONE-FROM-APPLE")
        XCTAssertEqual(simctl.cloneCalls.first?.source, "APPLE")
        let data = try fs.readFile(at: "/repos/Demo-alpha/.vch/state.json")
        let state = try TaskState.parse(data)
        XCTAssertEqual(state.simulator?.sourceKind, .appleTemplate)
    }

    /// A booted warm template is unhealthy — skip it and fall through
    /// to the Apple-template scan rather than silently cloning from a
    /// degraded source.
    func testEnsureCloneSkipsBootedWarmTemplate() throws {
        let warm = device("WARM-BOOTED", "vch-warm[iPhone 16:iOS 26.4]",
                          "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                          .init(major: 26, minor: 4),
                          state: "Booted")
        let apple = device("APPLE", "iPhone 16",
                           "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                           .init(major: 26, minor: 4))
        let (service, _, simctl) = makeService(
            seedingState: emptyState("alpha"),
            devices: [warm, apple],
            allDevicesOverride: [warm, apple],
            cloneReturnsUDID: "CLONE-FROM-APPLE"
        )
        _ = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16",
            requestedRuntime: "iOS 26.4"
        )
        XCTAssertEqual(simctl.cloneCalls.first?.source, "APPLE")
    }

    /// A warm template whose runtime is no longer installed (Apple
    /// uninstalled the runtime DMG via Xcode, etc.) shows up in
    /// `simctl list` with `isAvailable == false`. The reuse path must
    /// skip it and fall through to the Apple-template scan rather
    /// than cloning off a stale source. Exercises the `available`
    /// branch of `pickWarmTemplate` independently of the booted one.
    func testEnsureCloneSkipsStaleWarmTemplate() throws {
        let warm = device("WARM-STALE", "vch-warm[iPhone 16:iOS 26.4]",
                          "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                          .init(major: 26, minor: 4),
                          available: false)
        let apple = device("APPLE", "iPhone 16",
                           "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                           .init(major: 26, minor: 4))
        let (service, _, simctl) = makeService(
            seedingState: emptyState("alpha"),
            devices: [warm, apple],
            allDevicesOverride: [warm, apple],
            cloneReturnsUDID: "CLONE-FROM-APPLE"
        )
        _ = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16",
            requestedRuntime: "iOS 26.4"
        )
        XCTAssertEqual(simctl.cloneCalls.first?.source, "APPLE")
    }

    /// When no warm template matches the (device, runtime) pair, fall
    /// through cleanly.
    func testEnsureCloneFallsThroughWhenNoWarmTemplateMatches() throws {
        let warm = device("WARM-OTHER", "vch-warm[iPhone 17:iOS 26.4]",
                          "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                          .init(major: 26, minor: 4))
        let apple = device("APPLE", "iPhone 16",
                           "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                           .init(major: 26, minor: 4))
        let (service, _, simctl) = makeService(
            seedingState: emptyState("alpha"),
            devices: [warm, apple],
            allDevicesOverride: [warm, apple],
            cloneReturnsUDID: "CLONE-FROM-APPLE"
        )
        _ = try service.ensureClone(
            task: try TaskName("alpha"),
            requestedDevice: "iPhone 16",
            requestedRuntime: "iOS 26.4"
        )
        XCTAssertEqual(simctl.cloneCalls.first?.source, "APPLE")
    }
}
