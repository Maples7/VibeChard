import XCTest
@testable import VibeChardCore

final class XcodebuildFailureHintTests: XCTestCase {
    func testSimulatorPreflightBusyHintFires() {
        let log = """
        Failed to install or launch the test runner.
        Simulator device failed to launch com.maples7.BeanLedger.
        The request was denied by service delegate (SBMainWorkspace) for reason: Busy ("Application failed preflight checks").
        """

        let hint = XcodebuildFailureHint.simulatorPreflightBusyHint(
            logText: log,
            command: .test,
            taskName: "watch-sync-robustness",
            device: "BeanLedger Test iPhone Template 20260514 Fresh"
        )

        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("SBMainWorkspace Busy"))
        XCTAssertTrue(hint!.contains("vch test 'watch-sync-robustness' --erase-clone [same flags]"))
        XCTAssertTrue(hint!.contains("vch sim erase 'watch-sync-robustness' --device 'BeanLedger Test iPhone Template 20260514 Fresh'"))
    }

    func testSimulatorPreflightBusyHintRequiresWorkspaceMarker() {
        let log = """
        The request was denied for reason: Busy ("Application failed preflight checks").
        """

        XCTAssertNil(
            XcodebuildFailureHint.simulatorPreflightBusyHint(
                logText: log,
                command: .test,
                taskName: "alpha",
                device: "iPhone 16"
            )
        )
    }

    func testSimulatorPreflightBusyHintQuotesDeviceNames() {
        let log = """
        The request was denied by service delegate (SBMainWorkspace) for reason: Busy.
        """

        let hint = XcodebuildFailureHint.simulatorPreflightBusyHint(
            logText: log,
            command: .build,
            taskName: "alpha",
            device: "QA's iPhone"
        )

        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("vch sim erase 'alpha' --device 'QA'\\''s iPhone'"))
    }

    func testSimulatorDestinationHintFires() {
        let log = """
        xcodebuild: error: Unable to find a destination matching the provided destination specifier:
                { platform:iOS Simulator, name:iPhone 16 }
        """

        let hint = XcodebuildFailureHint.simulatorDestinationHint(
            logText: log,
            command: .build,
            taskName: "clean-bundle-identifiers",
            scheme: "AlloCurve"
        )

        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("could not select a simulator destination"))
        XCTAssertTrue(hint!.contains("vch build 'clean-bundle-identifiers' --scheme 'AlloCurve' --device <template-name>"))
        XCTAssertTrue(hint!.contains("xcrun simctl list devices available"))
    }

    func testSimulatorDestinationHintIgnoresCompileErrors() {
        let log = """
        SwiftCompile normal arm64 /tmp/App/View.swift
        /tmp/App/View.swift:12:8: error: cannot find 'foo' in scope
        """

        XCTAssertNil(XcodebuildFailureHint.simulatorDestinationHint(
            logText: log,
            command: .test,
            taskName: "alpha",
            scheme: "App"
        ))
    }
}