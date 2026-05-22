import XCTest
@testable import VibeChardCore

final class TestExecutionHangDiagnosticTests: XCTestCase {
    func testRenderIncludesContextAndRecoveryCommands() {
        let diagnostic = TestExecutionHangDiagnostic(
            taskName: "alpha.beta",
            pid: 42,
            idleSeconds: 0.25,
            elapsedSeconds: 7.5,
            command: ["xcodebuild", "-scheme", "My App", "test"],
            simulator: .init(
                name: "iPhone 16-vch-alpha.beta",
                udid: "SIM-1",
                state: "Booted",
                runtime: "iOS 26.5"
            ),
            logPath: "/tmp/alpha/.vch/last-test.log",
            resultBundlePath: "/tmp/alpha/.agent-build/Result.xcresult"
        )

        let rendered = diagnostic.render()

        XCTAssertTrue(rendered.contains("test execution did not complete"), rendered)
        XCTAssertTrue(rendered.contains("task: alpha.beta"), rendered)
        XCTAssertTrue(rendered.contains("xcodebuild PID: 42"), rendered)
        XCTAssertTrue(rendered.contains("simulator: iPhone 16-vch-alpha.beta (SIM-1, state: Booted, runtime: iOS 26.5)"), rendered)
        XCTAssertTrue(rendered.contains("command: xcodebuild -scheme 'My App' test"), rendered)
        XCTAssertTrue(rendered.contains("log: /tmp/alpha/.vch/last-test.log"), rendered)
        XCTAssertTrue(rendered.contains("result: /tmp/alpha/.agent-build/Result.xcresult"), rendered)
        XCTAssertTrue(rendered.contains("rg 'alpha\\.beta|42|xcodebuild|xctest'"), rendered)
        XCTAssertTrue(rendered.contains("vch clean alpha.beta --kill-stuck-tests"), rendered)
    }

    func testRenderHandlesNoSimulatorAndLongDurations() {
        let diagnostic = TestExecutionHangDiagnostic(
            taskName: "alpha",
            pid: 99,
            idleSeconds: 12.4,
            elapsedSeconds: 65.2,
            command: ["xcodebuild", "test"],
            simulator: nil,
            logPath: "/tmp/alpha/.vch/last-test.log",
            resultBundlePath: "/tmp/alpha/.agent-build/Result.xcresult"
        )

        let rendered = diagnostic.render()

        XCTAssertTrue(rendered.contains("no xcodebuild output for 12s"), rendered)
        XCTAssertTrue(rendered.contains("elapsed: 65s"), rendered)
        XCTAssertTrue(rendered.contains("simulator: none resolved by vch"), rendered)
    }

    func testRenderShellQuotesCommandsAndRecoveryArgs() {
        let diagnostic = TestExecutionHangDiagnostic(
            taskName: "alpha' beta",
            pid: 7,
            idleSeconds: 1,
            elapsedSeconds: 2,
            command: ["xcodebuild", "-scheme", "Bob's App", "test"],
            simulator: nil,
            logPath: "/tmp/log path/last-test.log",
            resultBundlePath: "/tmp/result path/Result.xcresult"
        )

        let rendered = diagnostic.render()

        XCTAssertTrue(rendered.contains("command: xcodebuild -scheme 'Bob'\\''s App' test"), rendered)
        XCTAssertTrue(rendered.contains("vch clean 'alpha'\\'' beta' --kill-stuck-tests"), rendered)
    }

    func testRenderEscapesRegexMetacharactersInProcessSearch() {
        let taskName = "a.*+?^$|()[]{}"
        let diagnostic = TestExecutionHangDiagnostic(
            taskName: taskName,
            pid: 7,
            idleSeconds: 1,
            elapsedSeconds: 2,
            command: ["xcodebuild", "test"],
            simulator: nil,
            logPath: "/tmp/log",
            resultBundlePath: "/tmp/result"
        )

        let rendered = diagnostic.render()
        let escapedTaskName = NSRegularExpression.escapedPattern(for: taskName)

        XCTAssertTrue(rendered.contains("rg '\(escapedTaskName)|7|xcodebuild|xctest'"), rendered)
    }
}