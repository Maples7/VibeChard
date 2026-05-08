import XCTest
@testable import VibeChardCore

final class TaskNameTests: XCTestCase {

    func testAcceptsTypicalNames() throws {
        for name in ["foo", "bar-1", "v1.2.3", "a", "feature_x", "Auth-2025"] {
            XCTAssertNoThrow(try TaskName(name), "expected '\(name)' to validate")
        }
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try TaskName("")) { error in
            assertInvalidName(error, contains: "must not be empty")
        }
    }

    func testRejectsLeadingDash() {
        XCTAssertThrowsError(try TaskName("-foo")) { error in
            assertInvalidName(error, contains: "'-'")
        }
    }

    func testRejectsLeadingDotOrUnderscoreOrDash() {
        for n in [".foo", "_foo", "-foo"] {
            XCTAssertThrowsError(try TaskName(n))
        }
    }

    func testRejectsSlashAndSpaces() {
        for n in ["foo/bar", "foo bar", "foo\tbar", "foo:bar"] {
            XCTAssertThrowsError(try TaskName(n), "expected '\(n)' to fail")
        }
    }

    func testRejectsTooLong() {
        let longName = String(repeating: "a", count: TaskName.maxLength + 1)
        XCTAssertThrowsError(try TaskName(longName))
    }

    func testAcceptsExactlyMaxLength() throws {
        let name = String(repeating: "a", count: TaskName.maxLength)
        XCTAssertNoThrow(try TaskName(name))
    }

    func testRejectsReservedSubcommands() {
        for r in ["new", "list", "ls", "path", "exec", "open",
                  "build", "test", "run", "logs", "sim", "state", "completions",
                  "clean",
                  "remove", "rm", "repair", "doctor", "land",
                  "shellenv", "version", "help"] {
            XCTAssertThrowsError(try TaskName(r), "expected reserved name '\(r)' to fail") { error in
                assertInvalidName(error, contains: "reserved subcommand")
            }
        }
    }

    func testBranchName() throws {
        let task = try TaskName("foo")
        XCTAssertEqual(task.branchName, "agent/foo")
    }

    // MARK: - helpers

    private func assertInvalidName(_ error: Error, contains needle: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard let e = error as? VibeChardError, case .invalidTaskName(_, let reason) = e else {
            return XCTFail("expected VibeChardError.invalidTaskName, got \(error)", file: file, line: line)
        }
        XCTAssertTrue(reason.contains(needle), "reason '\(reason)' does not contain '\(needle)'", file: file, line: line)
    }
}
