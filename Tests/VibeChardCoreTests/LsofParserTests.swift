import XCTest
@testable import VibeChardCore

final class LsofParserTests: XCTestCase {

    func testParsesSinglePidWithOneHeldPath() {
        let output = """
        p1234
        cVS Code
        n/repos/Demo-alpha/src/main.swift
        """
        let holders = LsofParser.parse(
            fieldOutput: output,
            worktreePath: "/repos/Demo-alpha",
            selfPID: 99
        )
        XCTAssertEqual(holders.count, 1)
        XCTAssertEqual(holders.first?.pid, 1234)
        XCTAssertEqual(holders.first?.command, "VS Code")
        XCTAssertEqual(holders.first?.samplePath, "/repos/Demo-alpha/src/main.swift")
    }

    func testDeduplicatesByPidKeepingFirstPath() {
        let output = """
        p1234
        cXcode
        n/repos/Demo-alpha/Sources/A.swift
        n/repos/Demo-alpha/Sources/B.swift
        """
        let holders = LsofParser.parse(
            fieldOutput: output,
            worktreePath: "/repos/Demo-alpha",
            selfPID: 99
        )
        XCTAssertEqual(holders.count, 1)
        XCTAssertEqual(holders.first?.samplePath,
                       "/repos/Demo-alpha/Sources/A.swift")
    }

    func testIgnoresPathsOutsideWorktree() {
        let output = """
        p1234
        cVS Code
        n/repos/Other/file.swift
        p5678
        cgit
        n/repos/Demo-alpha/.git/index
        """
        let holders = LsofParser.parse(
            fieldOutput: output,
            worktreePath: "/repos/Demo-alpha",
            selfPID: 99
        )
        XCTAssertEqual(holders.count, 1)
        XCTAssertEqual(holders.first?.pid, 5678)
        XCTAssertEqual(holders.first?.command, "git")
    }

    // Crucial guardrail: a worktree literally named `Foo` must NOT match
    // its sibling `Foo-bar`. Without the trailing-slash discipline the
    // hasPrefix would false-positive.
    func testDoesNotMatchSiblingWithSamePrefix() {
        let output = """
        p1234
        cEditor
        n/repos/Demo-alpha-extra/file.swift
        """
        let holders = LsofParser.parse(
            fieldOutput: output,
            worktreePath: "/repos/Demo-alpha",
            selfPID: 99
        )
        XCTAssertEqual(holders.count, 0)
    }

    func testFiltersSelfPID() {
        let output = """
        p4242
        cvch
        n/repos/Demo-alpha/.vch/state.json
        p9999
        ccode
        n/repos/Demo-alpha/AGENTS.md
        """
        let holders = LsofParser.parse(
            fieldOutput: output,
            worktreePath: "/repos/Demo-alpha",
            selfPID: 4242
        )
        XCTAssertEqual(holders.map(\.pid), [9999])
    }

    func testEmptyWorktreePathYieldsNoHolders() {
        let output = """
        p1234
        cAnything
        n/some/path
        """
        let holders = LsofParser.parse(
            fieldOutput: output,
            worktreePath: "",
            selfPID: 99
        )
        XCTAssertEqual(holders, [])
    }

    func testIgnoresUnknownFieldKinds() {
        // `f` and `t` lines (file descriptor type, file type) appear in
        // real lsof output and must be silently skipped.
        let output = """
        p1234
        cXcode
        fcwd
        ttxt
        n/repos/Demo-alpha/Sources/main.swift
        """
        let holders = LsofParser.parse(
            fieldOutput: output,
            worktreePath: "/repos/Demo-alpha",
            selfPID: 99
        )
        XCTAssertEqual(holders.count, 1)
        XCTAssertEqual(holders.first?.samplePath,
                       "/repos/Demo-alpha/Sources/main.swift")
    }
}
