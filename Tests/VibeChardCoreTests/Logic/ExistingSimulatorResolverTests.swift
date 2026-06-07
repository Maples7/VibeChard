import XCTest
@testable import VibeChardCore

final class ExistingSimulatorResolverTests: XCTestCase {

    private func device(
        _ udid: String,
        _ name: String,
        runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        version: SimRuntimeVersion? = .init(major: 26, minor: 5),
        state: String? = "Booted"
    ) -> SimDevice {
        SimDevice(
            udid: udid, name: name, runtime: runtime,
            runtimeVersion: version, isAvailable: true, state: state
        )
    }

    // MARK: - resolve by UDID

    func testResolvesByExactUDID() throws {
        let devices = [
            device("AAAA-1111", "iPhone 16"),
            device("BBBB-2222", "iPhone 16 Pro"),
        ]
        let match = try ExistingSimulatorResolver.resolve(
            selector: "BBBB-2222", devices: devices
        )
        XCTAssertEqual(match.udid, "BBBB-2222")
        XCTAssertEqual(match.name, "iPhone 16 Pro")
        XCTAssertEqual(match.runtime?.platform, .iOS)
        XCTAssertEqual(match.runtime?.dottedLabel, "iOS 26.5")
    }

    func testUDIDMatchIsCaseInsensitive() throws {
        let devices = [device("E8B1BF6D-DEAD-BEEF", "iPhone 16")]
        let match = try ExistingSimulatorResolver.resolve(
            selector: "e8b1bf6d-dead-beef", devices: devices
        )
        XCTAssertEqual(match.udid, "E8B1BF6D-DEAD-BEEF")
    }

    func testUDIDMatchWinsOverAName() throws {
        // A device whose UDID equals the selector wins even when other
        // devices carry that string as a name (contrived, but proves
        // the UDID branch runs first).
        let devices = [
            device("iPhone 16", "decoy"),       // udid literally "iPhone 16"
            device("CCCC-3333", "iPhone 16"),   // name "iPhone 16"
        ]
        let match = try ExistingSimulatorResolver.resolve(
            selector: "iPhone 16", devices: devices
        )
        XCTAssertEqual(match.udid, "iPhone 16")
        XCTAssertEqual(match.name, "decoy")
    }

    // MARK: - resolve by name

    func testResolvesBySingleNameMatch() throws {
        let devices = [
            device("AAAA-1111", "iPhone 16"),
            device("BBBB-2222", "iPad Pro"),
        ]
        let match = try ExistingSimulatorResolver.resolve(
            selector: "iPad Pro", devices: devices
        )
        XCTAssertEqual(match.udid, "BBBB-2222")
        XCTAssertEqual(match.name, "iPad Pro")
    }

    func testThrowsNotFoundWhenNoMatch() {
        let devices = [device("AAAA-1111", "iPhone 16")]
        XCTAssertThrowsError(try ExistingSimulatorResolver.resolve(
            selector: "iPhone 99", devices: devices
        )) { err in
            guard case VibeChardError.existingSimulatorNotFound(let selector) = err else {
                return XCTFail("expected existingSimulatorNotFound, got \(err)")
            }
            XCTAssertEqual(selector, "iPhone 99")
        }
    }

    func testThrowsNotFoundForEmptyDeviceList() {
        XCTAssertThrowsError(try ExistingSimulatorResolver.resolve(
            selector: "iPhone 16", devices: []
        )) { err in
            guard case VibeChardError.existingSimulatorNotFound = err else {
                return XCTFail("expected existingSimulatorNotFound, got \(err)")
            }
        }
    }

    // MARK: - ambiguity

    func testThrowsAmbiguousWhenNameMatchesMultiple() {
        // Same device name on two runtimes — the classic ambiguity the
        // issue calls out. Candidates must be listed newest-runtime
        // first with the UDID so the user can re-run by UDID.
        let devices = [
            device("OLD-1111", "iPhone 16",
                   runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                   version: .init(major: 18, minor: 0)),
            device("NEW-2222", "iPhone 16",
                   runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                   version: .init(major: 26, minor: 5)),
        ]
        XCTAssertThrowsError(try ExistingSimulatorResolver.resolve(
            selector: "iPhone 16", devices: devices
        )) { err in
            guard case VibeChardError.existingSimulatorAmbiguous(let selector, let candidates) = err else {
                return XCTFail("expected existingSimulatorAmbiguous, got \(err)")
            }
            XCTAssertEqual(selector, "iPhone 16")
            XCTAssertEqual(candidates, [
                "NEW-2222 — iOS 26.5",
                "OLD-1111 — iOS 18.0",
            ])
        }
    }

    func testAmbiguousSortsUnknownRuntimeLast() {
        let devices = [
            device("UNK-0000", "iPhone 16", runtime: "garbage", version: nil),
            device("NEW-2222", "iPhone 16",
                   runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                   version: .init(major: 26, minor: 5)),
        ]
        XCTAssertThrowsError(try ExistingSimulatorResolver.resolve(
            selector: "iPhone 16", devices: devices
        )) { err in
            guard case VibeChardError.existingSimulatorAmbiguous(_, let candidates) = err else {
                return XCTFail("expected existingSimulatorAmbiguous, got \(err)")
            }
            XCTAssertEqual(candidates, [
                "NEW-2222 — iOS 26.5",
                "UNK-0000 — unknown runtime",
            ])
        }
    }

    // MARK: - empty selector

    func testThrowsMissingArgumentForEmptySelector() {
        XCTAssertThrowsError(try ExistingSimulatorResolver.resolve(
            selector: "   ", devices: [device("A", "iPhone 16")]
        )) { err in
            guard case VibeChardError.missingArgument(let name) = err else {
                return XCTFail("expected missingArgument, got \(err)")
            }
            XCTAssertEqual(name, "--existing-sim")
        }
    }

    func testTrimsWhitespaceFromSelector() throws {
        let devices = [device("AAAA-1111", "iPhone 16")]
        let match = try ExistingSimulatorResolver.resolve(
            selector: "  iPhone 16  ", devices: devices
        )
        XCTAssertEqual(match.udid, "AAAA-1111")
    }

    // MARK: - validateOptions

    func testValidateOptionsNoOpWhenExistingSimNil() throws {
        // Every other flag is irrelevant when --existing-sim is absent.
        try ExistingSimulatorResolver.validateOptions(
            existingSim: nil, device: "iPhone 16", runtime: "iOS 26.5",
            eraseClone: true, shutdownTemplate: true
        )
    }

    func testValidateOptionsAllowsCleanExistingSim() throws {
        try ExistingSimulatorResolver.validateOptions(
            existingSim: "iPhone 16", device: nil, runtime: nil,
            eraseClone: false, shutdownTemplate: false
        )
    }

    func testValidateOptionsRejectsDevice() {
        XCTAssertThrowsError(try ExistingSimulatorResolver.validateOptions(
            existingSim: "iPhone 16", device: "iPhone 16 Pro", runtime: nil,
            eraseClone: false, shutdownTemplate: false
        )) { err in
            guard case VibeChardError.existingSimulatorConflictsWithDevice = err else {
                return XCTFail("expected existingSimulatorConflictsWithDevice, got \(err)")
            }
        }
    }

    func testValidateOptionsRejectsRuntime() {
        XCTAssertThrowsError(try ExistingSimulatorResolver.validateOptions(
            existingSim: "iPhone 16", device: nil, runtime: "iOS 26.5",
            eraseClone: false, shutdownTemplate: false
        )) { err in
            guard case VibeChardError.existingSimulatorIncompatibleOption(let option) = err else {
                return XCTFail("expected existingSimulatorIncompatibleOption, got \(err)")
            }
            XCTAssertEqual(option, "--runtime")
        }
    }

    func testValidateOptionsRejectsEraseClone() {
        XCTAssertThrowsError(try ExistingSimulatorResolver.validateOptions(
            existingSim: "iPhone 16", device: nil, runtime: nil,
            eraseClone: true, shutdownTemplate: false
        )) { err in
            guard case VibeChardError.existingSimulatorIncompatibleOption(let option) = err else {
                return XCTFail("expected existingSimulatorIncompatibleOption, got \(err)")
            }
            XCTAssertEqual(option, "--erase-clone")
        }
    }

    func testValidateOptionsRejectsShutdownTemplate() {
        XCTAssertThrowsError(try ExistingSimulatorResolver.validateOptions(
            existingSim: "iPhone 16", device: nil, runtime: nil,
            eraseClone: false, shutdownTemplate: true
        )) { err in
            guard case VibeChardError.existingSimulatorIncompatibleOption(let option) = err else {
                return XCTFail("expected existingSimulatorIncompatibleOption, got \(err)")
            }
            XCTAssertEqual(option, "--shutdown-template")
        }
    }

    func testValidateOptionsRejectsNoSim() {
        XCTAssertThrowsError(try ExistingSimulatorResolver.validateOptions(
            existingSim: "iPhone 16", device: nil, runtime: nil,
            eraseClone: false, shutdownTemplate: false, noSim: true
        )) { err in
            guard case VibeChardError.existingSimulatorIncompatibleOption(let option) = err else {
                return XCTFail("expected existingSimulatorIncompatibleOption, got \(err)")
            }
            XCTAssertEqual(option, "--no-sim")
        }
    }

    func testValidateOptionsDeviceConflictWinsOverOtherFlags() {
        // --device is the most specific conflict; it should be reported
        // even when other incompatible flags are also set.
        XCTAssertThrowsError(try ExistingSimulatorResolver.validateOptions(
            existingSim: "iPhone 16", device: "iPhone 16 Pro", runtime: "iOS 26.5",
            eraseClone: true, shutdownTemplate: true, noSim: true
        )) { err in
            guard case VibeChardError.existingSimulatorConflictsWithDevice = err else {
                return XCTFail("expected existingSimulatorConflictsWithDevice, got \(err)")
            }
        }
    }

    func testValidateOptionsTreatsEmptyDeviceAndRuntimeAsAbsent() throws {
        // ArgumentParser hands empty strings for `--device ""`; treat
        // them as "not passed" so we don't reject a clean existing-sim.
        try ExistingSimulatorResolver.validateOptions(
            existingSim: "iPhone 16", device: "", runtime: "",
            eraseClone: false, shutdownTemplate: false
        )
    }

    // MARK: - exit codes

    func testExitCodeMapping() {
        XCTAssertEqual(
            VibeChardError.existingSimulatorNotFound(selector: "x").exitCode,
            ExitCode.business
        )
        XCTAssertEqual(
            VibeChardError.existingSimulatorAmbiguous(selector: "x", candidates: []).exitCode,
            ExitCode.business
        )
        XCTAssertEqual(
            VibeChardError.existingSimulatorConflictsWithDevice.exitCode,
            ExitCode.usage
        )
        XCTAssertEqual(
            VibeChardError.existingSimulatorIncompatibleOption(option: "--runtime").exitCode,
            ExitCode.usage
        )
    }
}
