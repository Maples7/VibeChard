import XCTest
@testable import VibeChardCore

final class SimctlCloneErrorsTests: XCTestCase {

    /// The exact phrase simctl emits when refusing to clone a booted
    /// device. The substring is what we anchor on; the surrounding
    /// "An error was encountered…" preamble is locale-neutral but not
    /// contractually stable. (#66)
    func testIsTemplateBootedMatchesActualSimctlOutput() {
        let stderr = """
        An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError.149, code=149):
        Unable to clone device in current state: Booted
        """
        XCTAssertTrue(SimctlCloneErrors.isTemplateBooted(stderr: stderr))
    }

    func testIsTemplateBootedMatchesBareNounPhrase() {
        XCTAssertTrue(SimctlCloneErrors.isTemplateBooted(
            stderr: "Unable to clone device in current state: Booted"
        ))
    }

    func testIsTemplateBootedDoesNotMatchUnrelatedFailures() {
        XCTAssertFalse(SimctlCloneErrors.isTemplateBooted(stderr: ""))
        XCTAssertFalse(SimctlCloneErrors.isTemplateBooted(
            stderr: "Invalid device type identifier"
        ))
        // A different "current state" message (Shutting Down) must not
        // match — only `Booted`. simctl can shut a device down at any
        // time without the user opting in to anything.
        XCTAssertFalse(SimctlCloneErrors.isTemplateBooted(
            stderr: "Unable to clone device in current state: Shutting Down"
        ))
    }
}
