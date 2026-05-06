import XCTest
@testable import VibeChardCore

final class PorcelainParserTests: XCTestCase {

    func testParsesSimpleMainAndLinkedWorktree() {
        let input = """
        worktree /Users/me/repo
        HEAD abc123def
        branch refs/heads/main

        worktree /Users/me/repo-foo
        HEAD def456789
        branch refs/heads/agent/foo

        """
        let entries = PorcelainParser.parseWorktreeList(input)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], WorktreeEntry(path: "/Users/me/repo", head: "abc123def", branch: "main"))
        XCTAssertEqual(entries[1], WorktreeEntry(path: "/Users/me/repo-foo", head: "def456789", branch: "agent/foo"))
    }

    func testParsesBareAndDetached() {
        let input = """
        worktree /Users/me/bare
        HEAD abc
        bare

        worktree /Users/me/detached
        HEAD def
        detached

        """
        let entries = PorcelainParser.parseWorktreeList(input)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isBare)
        XCTAssertTrue(entries[1].isDetached)
    }

    func testHandlesNoTrailingBlankLine() {
        let input = """
        worktree /a
        HEAD abc
        branch refs/heads/x
        """
        let entries = PorcelainParser.parseWorktreeList(input)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "/a")
        XCTAssertEqual(entries[0].branch, "x")
    }

    func testEmptyInput() {
        XCTAssertEqual(PorcelainParser.parseWorktreeList("").count, 0)
        XCTAssertEqual(PorcelainParser.parseWorktreeList("\n\n").count, 0)
    }
}
