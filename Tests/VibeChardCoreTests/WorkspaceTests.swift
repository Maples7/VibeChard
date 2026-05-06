import XCTest
@testable import VibeChardCore

final class WorkspaceTests: XCTestCase {

    func testStripsTrailingSlash() {
        let ws = Workspace(mainWorktreePath: "/Users/me/Repo/")
        XCTAssertEqual(ws.mainWorktreePath, "/Users/me/Repo")
        XCTAssertEqual(ws.parentDirectory, "/Users/me")
        XCTAssertEqual(ws.repoName, "Repo")
    }

    func testWorktreePathLayout() throws {
        let ws = Workspace(mainWorktreePath: "/Users/me/BeanLedger")
        let task = try TaskName("auth-redesign")
        XCTAssertEqual(ws.worktreePath(for: task), "/Users/me/BeanLedger-auth-redesign")
        XCTAssertEqual(ws.statePath(for: task), "/Users/me/BeanLedger-auth-redesign/.vch/state.json")
        XCTAssertEqual(ws.vchDir(for: task), "/Users/me/BeanLedger-auth-redesign/.vch")
        XCTAssertEqual(ws.vchBinDir(for: task), "/Users/me/BeanLedger-auth-redesign/.vch/bin")
        XCTAssertEqual(ws.agentBuildDir(for: task), "/Users/me/BeanLedger-auth-redesign/.agent-build")
        XCTAssertEqual(ws.derivedDataDir(for: task), "/Users/me/BeanLedger-auth-redesign/.agent-build/DerivedData")
        XCTAssertEqual(ws.moduleCacheDir(for: task), "/Users/me/BeanLedger-auth-redesign/.agent-build/ModuleCache")
        XCTAssertEqual(ws.swiftpmCacheDir(for: task), "/Users/me/BeanLedger-auth-redesign/.agent-build/SwiftPM")
        XCTAssertEqual(ws.resultBundlePath(for: task), "/Users/me/BeanLedger-auth-redesign/.agent-build/Result.xcresult")
    }

    func testTaskNameRawFromWorktreePath() {
        let ws = Workspace(mainWorktreePath: "/Users/me/BeanLedger")
        XCTAssertEqual(ws.taskNameRaw(forWorktreePath: "/Users/me/BeanLedger-foo"), "foo")
        XCTAssertEqual(ws.taskNameRaw(forWorktreePath: "/Users/me/BeanLedger-feature.x"), "feature.x")
        XCTAssertNil(ws.taskNameRaw(forWorktreePath: "/Users/me/BeanLedger"))
        XCTAssertNil(ws.taskNameRaw(forWorktreePath: "/Users/me/Other-foo"))
        XCTAssertNil(ws.taskNameRaw(forWorktreePath: "/Users/me/BeanLedger-")) // empty suffix
    }
}
