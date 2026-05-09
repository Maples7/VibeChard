import XCTest
@testable import VibeChardCore

/// Unit tests for the `vch-warm[<device>:<runtime>]` name pattern (#47).
/// The pattern is the only source of truth for warm-template
/// metadata on disk, so the parser must be exact.
final class WarmTemplateNameTests: XCTestCase {

    func testFormatProducesCanonicalLayout() {
        let name = WarmTemplateName.format(deviceName: "iPhone 16",
                                           runtimeLabel: "iOS 26.4")
        XCTAssertEqual(name, "vch-warm[iPhone 16:iOS 26.4]")
    }

    func testParsesCanonicalName() {
        let parsed = WarmTemplateName.parse("vch-warm[iPhone 16:iOS 26.4]")
        XCTAssertEqual(parsed?.deviceName, "iPhone 16")
        XCTAssertEqual(parsed?.runtimeLabel, "iOS 26.4")
    }

    func testParseRoundtripsViaFormat() {
        for (device, runtime) in [
            ("iPhone 16", "iOS 26.4"),
            ("iPhone 16 Pro Max", "iOS 26.0"),
            ("iPad Pro 13-inch (M4)", "iOS 18.6"),
            ("iPhone 16e", "iOS 26.1"),
        ] {
            let name = WarmTemplateName.format(deviceName: device, runtimeLabel: runtime)
            let parsed = WarmTemplateName.parse(name)
            XCTAssertEqual(parsed?.deviceName, device, "device for \(name)")
            XCTAssertEqual(parsed?.runtimeLabel, runtime, "runtime for \(name)")
        }
    }

    func testParseSplitsOnLastColon() {
        // Defensive: device names containing a colon (none today on
        // Apple devices, but the parser shouldn't break if Apple
        // ever ships one). The runtime label after the *last* colon
        // is the canonical iOS form.
        let parsed = WarmTemplateName.parse("vch-warm[Foo: Bar:iOS 26.4]")
        XCTAssertEqual(parsed?.deviceName, "Foo: Bar")
        XCTAssertEqual(parsed?.runtimeLabel, "iOS 26.4")
    }

    func testParseRejectsMissingPrefix() {
        XCTAssertNil(WarmTemplateName.parse("warm[iPhone 16:iOS 26.4]"))
    }

    func testParseRejectsMissingSuffix() {
        XCTAssertNil(WarmTemplateName.parse("vch-warm[iPhone 16:iOS 26.4"))
    }

    func testParseRejectsMissingColon() {
        XCTAssertNil(WarmTemplateName.parse("vch-warm[iPhone 16 iOS 26.4]"))
    }

    func testParseRejectsEmptyDeviceName() {
        XCTAssertNil(WarmTemplateName.parse("vch-warm[:iOS 26.4]"))
    }

    func testParseRejectsEmptyRuntimeLabel() {
        XCTAssertNil(WarmTemplateName.parse("vch-warm[iPhone 16:]"))
    }

    func testIsWarmTemplateNameDoesNotMatchPerTaskClones() {
        // Per-task clones use the `<device>-vch-<task>` suffix.
        // Both schemes share the substring "vch-" but only warm
        // templates start with `vch-warm[` and end with `]`.
        XCTAssertFalse(WarmTemplateName.isWarmTemplateName("iPhone 16-vch-add-paywall"))
        XCTAssertFalse(WarmTemplateName.isWarmTemplateName("iPhone 16 · vch[task]"))
        XCTAssertTrue(WarmTemplateName.isWarmTemplateName("vch-warm[iPhone 16:iOS 26.4]"))
    }
}
