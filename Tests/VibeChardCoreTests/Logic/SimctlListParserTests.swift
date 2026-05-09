import XCTest
@testable import VibeChardCore

final class SimctlListParserTests: XCTestCase {

    func testParsesAvailableiOSDevices() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
              {
                "udid": "AAAA-1",
                "name": "iPhone 17 Pro",
                "isAvailable": true,
                "state": "Shutdown"
              },
              {
                "udid": "AAAA-2",
                "name": "iPhone 17",
                "isAvailable": true,
                "state": "Shutdown"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-1": [
              {
                "udid": "BBBB-1",
                "name": "iPhone 16",
                "isAvailable": true,
                "state": "Shutdown"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-2": [
              {
                "udid": "CCCC-1",
                "name": "Apple Watch Series 10 (46mm)",
                "isAvailable": true
              }
            ]
          }
        }
        """
        let devices = try SimctlListParser.parse(json)
        XCTAssertEqual(devices.count, 4)
        let i17 = devices.first { $0.udid == "AAAA-1" }
        XCTAssertEqual(i17?.name, "iPhone 17 Pro")
        XCTAssertEqual(i17?.runtimeVersion, .init(major: 26, minor: 4))
        XCTAssertTrue(i17?.isAvailable ?? false)

        let watch = devices.first { $0.udid == "CCCC-1" }
        // Non-iOS runtimes parse but get no version (filtered out by picker).
        XCTAssertNil(watch?.runtimeVersion)
    }

    func testRuntimeVersionParsesIOSIdentifier() {
        XCTAssertEqual(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"),
            SimRuntimeVersion(major: 26, minor: 4)
        )
        XCTAssertEqual(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17"),
            SimRuntimeVersion(major: 17, minor: 0)
        )
        XCTAssertNil(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-2")
        )
    }

    func testRuntimeVersionOrdering() {
        XCTAssertGreaterThan(SimRuntimeVersion(major: 26, minor: 4),
                             SimRuntimeVersion(major: 18, minor: 1))
        XCTAssertGreaterThan(SimRuntimeVersion(major: 18, minor: 2),
                             SimRuntimeVersion(major: 18, minor: 1))
    }

    /// `iOSRuntimeIdentifier` and `parse(runtimeIdentifier:)` must
    /// round-trip so the canonical CoreSimulator ID we hand to
    /// `simctl create` (warm-template path, #47) is byte-identical
    /// with what `simctl list devices --json` reports back. Likewise
    /// `dottedLabel` is the source of truth for the human form used
    /// in warm-template names and `vch test --runtime` accepts.
    func testRuntimeVersionAccessorsRoundTrip() {
        let v = SimRuntimeVersion(major: 26, minor: 4)
        XCTAssertEqual(v.dottedLabel, "iOS 26.4")
        XCTAssertEqual(v.iOSRuntimeIdentifier,
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        XCTAssertEqual(SimRuntimeVersion.parse(runtimeIdentifier: v.iOSRuntimeIdentifier), v)
    }

    func testRejectsTopLevelGarbage() {
        XCTAssertThrowsError(try SimctlListParser.parse("not json"))
        XCTAssertThrowsError(try SimctlListParser.parse(#"{"foo":1}"#))
    }
}
