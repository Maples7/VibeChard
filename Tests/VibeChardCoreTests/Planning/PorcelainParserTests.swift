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

    // MARK: - parseStatusPorcelainZ (#7)

    func testStatusEmptyInput() {
        XCTAssertEqual(PorcelainParser.parseStatusPorcelainZ(""), [])
    }

    func testStatusSingleModifiedFile() {
        // Format: "XY path\0". `git status --porcelain -z` always emits
        // a trailing NUL after each entry.
        let input = " M Foo.swift\u{0}"
        XCTAssertEqual(PorcelainParser.parseStatusPorcelainZ(input), ["Foo.swift"])
    }

    func testStatusUntrackedAndModifiedMix() {
        let input = " M Sources/A.swift\u{0}?? new.txt\u{0}M  Sources/B.swift\u{0}"
        XCTAssertEqual(
            PorcelainParser.parseStatusPorcelainZ(input),
            ["Sources/A.swift", "new.txt", "Sources/B.swift"]
        )
    }

    func testStatusRenameProducesTwoPaths() {
        // Rename: "R  new\0old\0" — the old path comes in the *next*
        // NUL-separated token. Both should appear in the result so
        // `vch land`'s overlap check covers both ends of the rename.
        let input = "R  new.swift\u{0}old.swift\u{0}"
        XCTAssertEqual(
            PorcelainParser.parseStatusPorcelainZ(input),
            ["new.swift", "old.swift"]
        )
    }

    func testStatusCopyProducesTwoPaths() {
        // Same shape as rename but with C in the XY field.
        let input = "C  copy.swift\u{0}src.swift\u{0}"
        XCTAssertEqual(
            PorcelainParser.parseStatusPorcelainZ(input),
            ["copy.swift", "src.swift"]
        )
    }

    func testStatusRenameMixedWithModified() {
        // Modified, then a rename, then an untracked. Make sure the
        // rename's two-token consumption doesn't swallow the next
        // entry.
        let input = " M Foo.swift\u{0}R  new.swift\u{0}old.swift\u{0}?? z.txt\u{0}"
        XCTAssertEqual(
            PorcelainParser.parseStatusPorcelainZ(input),
            ["Foo.swift", "new.swift", "old.swift", "z.txt"]
        )
    }

    func testStatusPathWithSpacesAndQuotes() {
        // -z output is verbatim — no quoting. Paths with spaces come
        // through unmangled.
        let input = "?? path with spaces.swift\u{0}"
        XCTAssertEqual(
            PorcelainParser.parseStatusPorcelainZ(input),
            ["path with spaces.swift"]
        )
    }

    func testStatusIgnoresTooShortTokens() {
        // Defensive: if git ever emits a malformed entry < 4 chars,
        // skip it instead of crashing.
        let input = "X\u{0} M Foo.swift\u{0}"
        XCTAssertEqual(
            PorcelainParser.parseStatusPorcelainZ(input),
            ["Foo.swift"]
        )
    }

    func testStatusTruncatedRenameDoesNotCrash() {
        // Rename advertised but no follow-up token. Treat the "R "
        // entry as a single path and stop cleanly.
        let input = "R  new.swift\u{0}"
        XCTAssertEqual(
            PorcelainParser.parseStatusPorcelainZ(input),
            ["new.swift"]
        )
    }
}
