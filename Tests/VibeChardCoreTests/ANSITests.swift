import XCTest
@testable import VibeChardCore

final class ANSITests: XCTestCase {

    // MARK: - Policy

    func testNoColorEnvDisablesEvenOnTTY() {
        let env = ["NO_COLOR": "1"]
        XCTAssertFalse(ANSI.shouldColorize(env: env, stdoutIsTTY: true))
    }

    func testEmptyNoColorIsIgnored() {
        // Per no-color.org: only non-empty NO_COLOR triggers the rule.
        let env = ["NO_COLOR": ""]
        XCTAssertTrue(ANSI.shouldColorize(env: env, stdoutIsTTY: true))
    }

    func testNoColorBeatsForceColor() {
        let env = ["NO_COLOR": "1", "FORCE_COLOR": "1"]
        XCTAssertFalse(ANSI.shouldColorize(env: env, stdoutIsTTY: true))
    }

    func testForceColorEnablesEvenWithoutTTY() {
        let env = ["FORCE_COLOR": "1"]
        XCTAssertTrue(ANSI.shouldColorize(env: env, stdoutIsTTY: false))
    }

    func testCliColorForceEnablesEvenWithoutTTY() {
        let env = ["CLICOLOR_FORCE": "1"]
        XCTAssertTrue(ANSI.shouldColorize(env: env, stdoutIsTTY: false))
    }

    func testForceColorZeroDoesNotForce() {
        // FORCE_COLOR=0 should NOT force-on. Default policy applies.
        let env = ["FORCE_COLOR": "0"]
        XCTAssertFalse(ANSI.shouldColorize(env: env, stdoutIsTTY: false))
        XCTAssertTrue(ANSI.shouldColorize(env: env, stdoutIsTTY: true))
    }

    func testForceColorFalseDoesNotForce() {
        let env = ["FORCE_COLOR": "false"]
        XCTAssertFalse(ANSI.shouldColorize(env: env, stdoutIsTTY: false))
    }

    func testEmptyForceColorDoesNotForce() {
        let env = ["FORCE_COLOR": ""]
        XCTAssertFalse(ANSI.shouldColorize(env: env, stdoutIsTTY: false))
    }

    func testDefaultFollowsTTY() {
        XCTAssertTrue(ANSI.shouldColorize(env: [:], stdoutIsTTY: true))
        XCTAssertFalse(ANSI.shouldColorize(env: [:], stdoutIsTTY: false))
    }

    // MARK: - Wrapping

    func testWrapDisabledReturnsInputUnchanged() {
        XCTAssertEqual(ANSI.wrap("hello", .ok, enabled: false), "hello")
        XCTAssertEqual(ANSI.wrap("hello", .fail, enabled: false), "hello")
    }

    func testWrapNoneStyleReturnsInputUnchanged() {
        // Even when enabled, .none has no codes -> no escape sequences.
        XCTAssertEqual(ANSI.wrap("hello", .none, enabled: true), "hello")
    }

    func testWrapEmitsExpectedCodes() {
        // .ok = bold (1) + bright green (92)
        XCTAssertEqual(
            ANSI.wrap("ok", .ok, enabled: true),
            "\u{001B}[1;92mok\u{001B}[0m"
        )
        // .fail = bold (1) + bright red (91)
        XCTAssertEqual(
            ANSI.wrap("fail", .fail, enabled: true),
            "\u{001B}[1;91mfail\u{001B}[0m"
        )
        // .branch = bright magenta (95) — single code, no semicolon.
        XCTAssertEqual(
            ANSI.wrap("agent/foo", .branch, enabled: true),
            "\u{001B}[95magent/foo\u{001B}[0m"
        )
        // .placeholder = dim (2)
        XCTAssertEqual(
            ANSI.wrap("-", .placeholder, enabled: true),
            "\u{001B}[2m-\u{001B}[0m"
        )
    }

    func testWrapPreservesPaddingForAlignment() {
        // The CLI pads BEFORE wrapping so columns align even when
        // colors are on. Assert the padded whitespace survives.
        let padded = "ok  "
        let out = ANSI.wrap(padded, .ok, enabled: true)
        XCTAssertTrue(out.contains(padded))
        XCTAssertTrue(out.hasPrefix("\u{001B}["))
        XCTAssertTrue(out.hasSuffix("\u{001B}[0m"))
    }
}
