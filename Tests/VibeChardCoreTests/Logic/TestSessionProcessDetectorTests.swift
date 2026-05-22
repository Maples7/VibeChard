import XCTest
@testable import VibeChardCore

final class TestSessionProcessDetectorTests: XCTestCase {
    private let worktree = "/Users/me/src/BeanLedger-v310-audit-fixes"
    private let derived = "/Users/me/src/BeanLedger-v310-audit-fixes/.agent-build/DerivedData"
    private let resultBundle = "/Users/me/src/BeanLedger-v310-audit-fixes/.agent-build/Result.xcresult"

    func testParsesPsPidAndFullCommand() {
        let entries = ProcessListParser.parse(psOutput: """
          101 /usr/bin/env xcodebuild -scheme BeanLedger test
        bad-pid ignored
          102 /Applications/Visual Studio Code.app/Contents/MacOS/Electron --type=renderer
        """)

        XCTAssertEqual(entries, [
            .init(pid: 101, command: "/usr/bin/env xcodebuild -scheme BeanLedger test"),
            .init(pid: 102, command: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron --type=renderer"),
        ])
    }

    func testDetectsTaskScopedVchTestXcodebuildAndHost() {
        let entries: [ProcessListEntry] = [
            .init(pid: 10, command: "vch test v310-audit-fixes --scheme BeanLedger --device iPhone 16"),
            .init(pid: 11, command: "/usr/bin/env xcodebuild -scheme BeanLedger -derivedDataPath \(derived) -resultBundlePath \(resultBundle) test"),
            .init(pid: 12, command: "/Users/me/Library/Developer/XCTestDevices/SIM-1/data/Containers/Bundle/Application/123/BeanLedger.app/BeanLedger"),
            .init(pid: 13, command: "/usr/bin/env xcodebuild -scheme Other -derivedDataPath /tmp/Other -resultBundlePath /tmp/Other.xcresult test"),
            .init(pid: 14, command: "/Users/me/Library/Developer/XCTestDevices/SIM-2/data/Containers/Bundle/Application/123/BeanLedger.app/BeanLedger"),
        ]

        let processes = TestSessionProcessDetector.detect(
            entries: entries,
            taskName: "v310-audit-fixes",
            worktreePath: worktree,
            derivedDataPath: derived,
            resultBundlePath: resultBundle,
            scheme: "BeanLedger",
            simulatorUDIDs: ["SIM-1"],
            selfPID: 99
        )

        XCTAssertEqual(processes.map(\.pid), [10, 11, 12])
        XCTAssertEqual(processes.map(\.kind), [.vchTest, .xcodebuild, .xctestHost])
    }

    func testDoesNotReportHostWithoutScheme() {
        let entries: [ProcessListEntry] = [
            .init(pid: 12, command: "/Users/me/Library/Developer/XCTestDevices/ABC/BeanLedger.app/BeanLedger"),
        ]

        let processes = TestSessionProcessDetector.detect(
            entries: entries,
            taskName: "v310-audit-fixes",
            worktreePath: worktree,
            derivedDataPath: derived,
            resultBundlePath: resultBundle,
            scheme: nil,
            simulatorUDIDs: ["ABC"],
            selfPID: 99
        )

        XCTAssertEqual(processes, [])
    }

    func testDoesNotReportHostCandidateWithoutDirectMatch() {
        let entries: [ProcessListEntry] = [
            .init(pid: 12, command: "/Users/me/Library/Developer/XCTestDevices/SIM-1/data/Containers/Bundle/Application/123/BeanLedger.app/BeanLedger"),
        ]

        let processes = TestSessionProcessDetector.detect(
            entries: entries,
            taskName: "v310-audit-fixes",
            worktreePath: worktree,
            derivedDataPath: derived,
            resultBundlePath: resultBundle,
            scheme: "BeanLedger",
            simulatorUDIDs: ["SIM-1"],
            selfPID: 99
        )

        XCTAssertEqual(processes, [])
    }

    // Regression for #131: an interrupted `vch build` can leave a
    // task-scoped `xcodebuild build` orphan holding `build.db`. It
    // must be detected for `vch clean --kill-stuck-tests` to recover.
    func testDetectsTaskScopedXcodebuildBuildLeftover() {
        let entries: [ProcessListEntry] = [
            .init(
                pid: 42,
                command: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme BeanLedger -derivedDataPath \(derived) -clonedSourcePackagesDirPath \(worktree)/.agent-build/SwiftPM -destination platform=iOS\\ Simulator,arch=arm64,id=SIM-1 build"
            ),
            // Unrelated xcodebuild build against a different worktree
            // must not be flagged.
            .init(
                pid: 43,
                command: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme Other -derivedDataPath /tmp/Other build"
            ),
        ]

        let processes = TestSessionProcessDetector.detect(
            entries: entries,
            taskName: "v310-audit-fixes",
            worktreePath: worktree,
            derivedDataPath: derived,
            resultBundlePath: resultBundle,
            scheme: "BeanLedger",
            simulatorUDIDs: ["SIM-1"],
            selfPID: 99
        )

        XCTAssertEqual(processes.map(\.pid), [42])
        XCTAssertEqual(processes.map(\.kind), [.xcodebuild])
    }
}