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

    func testCloneDisplayNameUsesMiddleDotConvention() throws {
        let (service, _, _) = makeService(
            seedingTask: "alpha",
            seedingState: emptyState("alpha")
        )
        let name = service.cloneDisplayName(originalName: "iPhone 16",
                                            task: try TaskName("alpha"))
        XCTAssertEqual(name, "iPhone 16 · vch[alpha]")
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
        XCTAssertEqual(resolved?.name, "iPhone 16 · vch[alpha]")
        XCTAssertTrue(resolved?.createdNow ?? false)

        // simctl.clone called exactly once with the right args.
        XCTAssertEqual(simctl.cloneCalls.count, 1)
        XCTAssertEqual(simctl.cloneCalls.first?.source, "TPL-NEW")
        XCTAssertEqual(simctl.cloneCalls.first?.newName, "iPhone 16 · vch[alpha]")

        // state.json now carries the simulator record.
        let data = try fs.readFile(at: "/repos/Demo-alpha/.vch/state.json")
        let state = try TaskState.parse(data)
        XCTAssertEqual(state.simulator?.cloneUDID, "CLONE-1")
        XCTAssertEqual(state.simulator?.sourceUDID, "TPL-NEW")
        XCTAssertEqual(state.simulator?.name, "iPhone 16 · vch[alpha]")
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
            name: "iPhone 16 · vch[alpha]"
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
}

// MARK: - test double

final class FakeSimctl: SimctlClient, @unchecked Sendable {
    var devices: [SimDevice] = []
    var cloneReturnsUDID: String = ""
    var bootCalls: [String] = []
    var deleteCalls: [String] = []
    var cloneCalls: [(source: String, newName: String)] = []
    var availableThrows: VibeChardError?
    var cloneThrows: VibeChardError?
    var bootThrows: VibeChardError?
    var deleteThrows: VibeChardError?

    func availableDevices() throws -> [SimDevice] {
        if let err = availableThrows { throw err }
        return devices
    }

    func clone(sourceUDID: String, newName: String) throws -> String {
        if let err = cloneThrows { throw err }
        cloneCalls.append((sourceUDID, newName))
        return cloneReturnsUDID
    }

    func bootstatusBoot(udid: String) throws {
        if let err = bootThrows { throw err }
        bootCalls.append(udid)
    }

    func delete(udid: String) throws {
        if let err = deleteThrows { throw err }
        deleteCalls.append(udid)
    }
}
