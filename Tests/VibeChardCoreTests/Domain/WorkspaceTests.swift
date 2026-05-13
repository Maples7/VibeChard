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
        // #9: tee'd test log lives under .vch/, not under .agent-build/,
        // so `vch rm` cleans it up alongside state.json.
        XCTAssertEqual(ws.lastTestLogPath(for: task), "/Users/me/BeanLedger-auth-redesign/.vch/last-test.log")
    }

    func testWorktreePathUsesExplicitTaskPathOverride() throws {
        let task = try TaskName("auth-redesign")
        let ws = Workspace(mainWorktreePath: "/Users/me/BeanLedger")
            .withWorktreePath("/Users/me/agent-session/", for: task)

        XCTAssertEqual(ws.worktreePath(for: task), "/Users/me/agent-session")
        XCTAssertEqual(ws.statePath(for: task), "/Users/me/agent-session/.vch/state.json")
        XCTAssertEqual(ws.derivedDataDir(for: task), "/Users/me/agent-session/.agent-build/DerivedData")
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
