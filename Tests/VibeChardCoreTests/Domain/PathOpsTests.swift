import XCTest

@testable import VibeChardCore

final class PathOpsTests: XCTestCase {

    // MARK: - Happy paths

    func testJoinsBaseWithSingleComponent() {
        XCTAssertEqual(PathOps.join("/Users/me/Repo", ".vch/state.json"),
                       "/Users/me/Repo/.vch/state.json")
    }

    func testJoinsMultipleComponents() {
        XCTAssertEqual(PathOps.join("/a", "b", "c", "d.txt"),
                       "/a/b/c/d.txt")
    }

    func testNoComponentsReturnsBase() {
        XCTAssertEqual(PathOps.join("/Users/me/Repo"),
                       "/Users/me/Repo")
    }

    // MARK: - Slash normalization (the whole point of the migration)

    func testNormalizesTrailingSlashOnBase() {
        // String interpolation would produce "/a//b". FilePath collapses.
        XCTAssertEqual(PathOps.join("/a/", "b"), "/a/b")
    }

    func testEmptyComponentsAreSkipped() {
        XCTAssertEqual(PathOps.join("/a", "", "b", "", "c"), "/a/b/c")
    }

    // MARK: - Regression shape — Workspace's internal joins go through PathOps.

    func testWorkspaceLayoutMatchesPathOps() throws {
        let ws = Workspace(mainWorktreePath: "/Users/me/BeanLedger")
        let task = try TaskName("auth")

        XCTAssertEqual(ws.worktreePath(for: task),
                       PathOps.join("/Users/me", "BeanLedger-auth"))
        XCTAssertEqual(ws.statePath(for: task),
                       PathOps.join(ws.worktreePath(for: task),
                                    Workspace.stateJsonRelativePath))
        XCTAssertEqual(ws.lastTestLogPath(for: task),
                       PathOps.join(ws.worktreePath(for: task),
                                    Workspace.lastTestLogRelativePath))
    }
}
