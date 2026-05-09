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
        XCTAssertEqual(i17?.runtimeVersion,
                       .init(platform: .iOS, major: 26, minor: 4))
        XCTAssertTrue(i17?.isAvailable ?? false)

        // After #58, non-iOS runtimes parse with their platform tag
        // — the warm-template feature now supports watchOS/tvOS/visionOS.
        let watch = devices.first { $0.udid == "CCCC-1" }
        XCTAssertEqual(watch?.runtimeVersion,
                       .init(platform: .watchOS, major: 11, minor: 2))
    }

    func testRuntimeVersionParsesAllSupportedPlatforms() {
        XCTAssertEqual(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"),
            SimRuntimeVersion(platform: .iOS, major: 26, minor: 4)
        )
        XCTAssertEqual(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17"),
            SimRuntimeVersion(platform: .iOS, major: 17, minor: 0)
        )
        XCTAssertEqual(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-5"),
            SimRuntimeVersion(platform: .watchOS, major: 11, minor: 5)
        )
        XCTAssertEqual(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-18-0"),
            SimRuntimeVersion(platform: .tvOS, major: 18, minor: 0)
        )
        // visionOS uses the `xrOS` slug in CoreSimulator identifiers.
        XCTAssertEqual(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-2-5"),
            SimRuntimeVersion(platform: .visionOS, major: 2, minor: 5)
        )
        // Unknown future platform → nil (until added to Platform enum).
        XCTAssertNil(
            SimRuntimeVersion.parse(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.macOS-15-0")
        )
    }

    func testRuntimeVersionOrdering() {
        // Same-platform comparisons go by (major, minor) — the
        // common case in pickNewestTemplate which only compares
        // devices sharing a name (and therefore a platform).
        XCTAssertGreaterThan(SimRuntimeVersion(major: 26, minor: 4),
                             SimRuntimeVersion(major: 18, minor: 1))
        XCTAssertGreaterThan(SimRuntimeVersion(major: 18, minor: 2),
                             SimRuntimeVersion(major: 18, minor: 1))
    }

    /// `runtimeIdentifier` and `parse(runtimeIdentifier:)` must
    /// round-trip so the canonical CoreSimulator ID we hand to
    /// `simctl create` (warm-template path, #47) is byte-identical
    /// with what `simctl list devices --json` reports back. Likewise
    /// `dottedLabel` is the source of truth for the human form used
    /// in warm-template names and `vch test --runtime` accepts.
    /// Covers all four supported platforms (#58); visionOS round-trips
    /// through the `xrOS` slug.
    func testRuntimeVersionAccessorsRoundTripAllPlatforms() {
        let cases: [(SimRuntimeVersion, dotted: String, identifier: String)] = [
            (SimRuntimeVersion(platform: .iOS, major: 26, minor: 4),
             "iOS 26.4",
             "com.apple.CoreSimulator.SimRuntime.iOS-26-4"),
            (SimRuntimeVersion(platform: .watchOS, major: 11, minor: 5),
             "watchOS 11.5",
             "com.apple.CoreSimulator.SimRuntime.watchOS-11-5"),
            (SimRuntimeVersion(platform: .tvOS, major: 18, minor: 0),
             "tvOS 18.0",
             "com.apple.CoreSimulator.SimRuntime.tvOS-18-0"),
            (SimRuntimeVersion(platform: .visionOS, major: 2, minor: 5),
             "visionOS 2.5",
             "com.apple.CoreSimulator.SimRuntime.xrOS-2-5"),
        ]
        for (v, dotted, identifier) in cases {
            XCTAssertEqual(v.dottedLabel, dotted)
            XCTAssertEqual(v.runtimeIdentifier, identifier)
            XCTAssertEqual(SimRuntimeVersion.parse(runtimeIdentifier: v.runtimeIdentifier), v)
        }
    }

    /// Backward-compat: `state.json` files written by vch ≤ v0.3.0
    /// store the iOS-only `runtimeIdentifier` as a raw string. After
    /// the #58 platform-aware refactor, the same string must continue
    /// to parse identically (i.e. with `platform == .iOS`) so old
    /// state.json files keep round-tripping through the field
    /// accessor and the simulator-binding-mismatch check.
    func testRuntimeVersionParsesLegacyIOSStateJSONIdentifier() {
        let parsed = SimRuntimeVersion.parse(
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
        )
        XCTAssertEqual(parsed?.platform, .iOS)
        XCTAssertEqual(parsed?.major, 26)
        XCTAssertEqual(parsed?.minor, 4)
        XCTAssertEqual(parsed?.dottedLabel, "iOS 26.4")
    }

    /// #58: end-to-end parse of a real `simctl list devices --json`
    /// payload that contains a visionOS device. Locks the load-bearing
    /// `xrOS` ↔ `.visionOS` translation on the parser surface that
    /// production code actually traverses on every `pickNewestTemplate`
    /// / warm-template call (the `parse(runtimeIdentifier:)` unit
    /// covers the same transform but in isolation; this guards the
    /// SimctlListParser → SimDevice → SimRuntimeVersion chain).
    func testParsesAvailableVisionOSDeviceJSONUsingXrOSSlug() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.xrOS-2-5": [
              {
                "udid": "VVVV-1",
                "name": "Apple Vision Pro",
                "isAvailable": true,
                "state": "Shutdown"
              }
            ]
          }
        }
        """
        let devices = try SimctlListParser.parse(json)
        XCTAssertEqual(devices.count, 1)
        let vision = devices.first
        XCTAssertEqual(vision?.name, "Apple Vision Pro")
        XCTAssertEqual(vision?.runtime,
                       "com.apple.CoreSimulator.SimRuntime.xrOS-2-5")
        XCTAssertEqual(vision?.runtimeVersion?.platform, .visionOS)
        XCTAssertEqual(vision?.runtimeVersion?.major, 2)
        XCTAssertEqual(vision?.runtimeVersion?.minor, 5)
        // dottedLabel must surface the human-friendly form regardless
        // of the slug simctl wrote into its JSON.
        XCTAssertEqual(vision?.runtimeVersion?.dottedLabel, "visionOS 2.5")
    }

    func testRejectsTopLevelGarbage() {
        XCTAssertThrowsError(try SimctlListParser.parse("not json"))
        XCTAssertThrowsError(try SimctlListParser.parse(#"{"foo":1}"#))
    }
}
