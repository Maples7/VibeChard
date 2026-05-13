import XCTest
@testable import VibeChardCore

final class SimInfoRendererTests: XCTestCase {

    // MARK: - resolveState

    func testResolveStateUsesLiveStateWhenPresent() {
        let live = SimDevice(
            udid: "U", name: "iPhone 16",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            runtimeVersion: .init(major: 18, minor: 0),
            isAvailable: true,
            state: "Booted"
        )
        XCTAssertEqual(SimInfoRenderer.resolveState(live: live), "Booted")
    }

    func testResolveStateReturnsUnknownWhenLiveDeviceHasNoState() {
        let live = SimDevice(
            udid: "U", name: "iPhone 16",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            runtimeVersion: .init(major: 18, minor: 0),
            isAvailable: true,
            state: nil
        )
        XCTAssertEqual(SimInfoRenderer.resolveState(live: live), "(unknown)")
    }

    func testResolveStateReturnsMissingHintWhenLiveIsNil() {
        // Sentinel mentions `vch doctor` — agent automation that
        // looks for the literal string would break if we changed it,
        // so pin it.
        XCTAssertEqual(
            SimInfoRenderer.resolveState(live: nil),
            "(missing — run `vch doctor`)"
        )
    }

    // MARK: - makeRow

    func testMakeRowCopiesEveryRecordField() {
        let record = TaskState.SimulatorRecord(
            cloneUDID: "IOS-CLONE", sourceUDID: "IOS-SRC",
            name: "iPhone 16-vch-alpha",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
        )
        let live = SimDevice(
            udid: "IOS-CLONE", name: "iPhone 16-vch-alpha",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            runtimeVersion: .init(major: 18, minor: 0),
            isAvailable: true,
            state: "Shutdown"
        )
        let row = SimInfoRenderer.makeRow(record: record, live: live)
        XCTAssertEqual(row.cloneUDID, "IOS-CLONE")
        XCTAssertEqual(row.sourceUDID, "IOS-SRC")
        XCTAssertEqual(row.name, "iPhone 16-vch-alpha")
        XCTAssertEqual(row.templateName, "iPhone 16")
        XCTAssertEqual(row.runtimeIdentifier,
                       "com.apple.CoreSimulator.SimRuntime.iOS-18-0")
        XCTAssertEqual(row.state, "Shutdown")
        XCTAssertTrue(row.presentInSimctl)
    }

    func testMakeRowMarksRowAsNotPresentWhenLiveIsNil() {
        let record = TaskState.SimulatorRecord(
            cloneUDID: "GONE", sourceUDID: "S",
            name: "iPhone 16-vch-alpha"
        )
        let row = SimInfoRenderer.makeRow(record: record, live: nil)
        XCTAssertFalse(row.presentInSimctl)
        XCTAssertEqual(row.state, "(missing — run `vch doctor`)")
    }

    // MARK: - Payload JSON wire shape (#99 breaking change)

    /// `vch sim info --json` on an unbound task must produce
    /// `{"task": ..., "bindings": []}` — the pre-#99 form
    /// `{"task": ..., "bound": null}` is gone. This is the
    /// breaking change the CHANGELOG calls out; the test pins the
    /// new shape so a regression to the old `bound` key is caught
    /// immediately.
    func testEmptyPayloadEncodesAsTaskAndEmptyBindingsArray() throws {
        let payload = SimInfoRenderer.Payload(task: "alpha", bindings: [])
        let json = try encode(payload)

        XCTAssertTrue(json.contains("\"task\""))
        XCTAssertTrue(json.contains("\"bindings\""))
        XCTAssertFalse(json.contains("\"bound\""),
                       "the pre-#99 `bound` key MUST be gone — got \(json)")

        // Decoded form is the load-bearing check — prettyPrinted's
        // exact whitespace for empty arrays varies between platforms,
        // so we don't rely on `"bindings" : []` as a literal substring.
        struct DecodedPayload: Decodable {
            let task: String
            let bindings: [DecodedRow]
        }
        struct DecodedRow: Decodable { let cloneUDID: String }
        let decoded = try JSONDecoder().decode(
            DecodedPayload.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.task, "alpha")
        XCTAssertTrue(decoded.bindings.isEmpty)
    }

    /// Multi-binding payload preserves every binding in insertion
    /// order and exposes each binding's fields (cloneUDID, name,
    /// templateName, runtimeIdentifier, state, presentInSimctl).
    /// This is the contract agent automation relies on after #99.
    func testMultiBindingPayloadEncodesEveryBindingInOrder() throws {
        let ios = SimInfoRenderer.BindingRow(
            cloneUDID: "IOS-CLONE", sourceUDID: "IOS-SRC",
            name: "iPhone 16-vch-alpha",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            state: "Booted",
            presentInSimctl: true
        )
        let watch = SimInfoRenderer.BindingRow(
            cloneUDID: "WATCH-CLONE", sourceUDID: "WATCH-SRC",
            name: "Apple Watch Series 10-vch-alpha",
            templateName: "Apple Watch Series 10",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
            state: "Shutdown",
            presentInSimctl: true
        )
        let payload = SimInfoRenderer.Payload(task: "alpha", bindings: [ios, watch])

        let json = try encode(payload)

        struct DecodedPayload: Decodable {
            let task: String
            let bindings: [DecodedRow]
        }
        struct DecodedRow: Decodable {
            let cloneUDID: String
            let sourceUDID: String
            let name: String
            let templateName: String?
            let runtimeIdentifier: String?
            let state: String
            let presentInSimctl: Bool
        }
        let decoded = try JSONDecoder().decode(
            DecodedPayload.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.task, "alpha")
        XCTAssertEqual(decoded.bindings.count, 2)
        XCTAssertEqual(decoded.bindings[0].cloneUDID, "IOS-CLONE")
        XCTAssertEqual(decoded.bindings[0].templateName, "iPhone 16")
        XCTAssertEqual(decoded.bindings[0].state, "Booted")
        XCTAssertTrue(decoded.bindings[0].presentInSimctl)
        XCTAssertEqual(decoded.bindings[1].cloneUDID, "WATCH-CLONE")
        XCTAssertEqual(decoded.bindings[1].runtimeIdentifier,
                       "com.apple.CoreSimulator.SimRuntime.watchOS-11-0")
        XCTAssertEqual(decoded.bindings[1].state, "Shutdown")
    }

    /// A binding whose live device is missing from `simctl` must
    /// still appear in the array (it's still recorded in
    /// `state.json`), but with `presentInSimctl == false` and the
    /// "(missing — run …)" sentinel. This is how `vch doctor` flags
    /// stale bindings to the user without dropping rows.
    func testPayloadKeepsMissingBindingsButFlagsThemNotPresent() throws {
        let row = SimInfoRenderer.makeRow(
            record: .init(cloneUDID: "GONE", sourceUDID: "S", name: "iPhone-X"),
            live: nil
        )
        let payload = SimInfoRenderer.Payload(task: "alpha", bindings: [row])
        let json = try encode(payload)

        XCTAssertTrue(json.contains("\"cloneUDID\" : \"GONE\""))
        XCTAssertTrue(json.contains("\"presentInSimctl\" : false"))
        XCTAssertTrue(json.contains("(missing — run"))
    }

    // MARK: - helpers

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
