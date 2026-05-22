import XCTest
@testable import VibeChardCore

final class TaskArgumentResolverTests: XCTestCase {
    func testExplicitNameWinsOverCurrentWorktree() throws {
        let task = try TaskArgumentResolver.resolve(
            explicit: "beta",
            current: try TaskName("alpha")
        )
        XCTAssertEqual(task.raw, "beta")
    }

    func testFallsBackToCurrentTaskWhenNameOmitted() throws {
        let task = try TaskArgumentResolver.resolve(
            explicit: nil,
            current: try TaskName("alpha")
        )
        XCTAssertEqual(task.raw, "alpha")
    }

    func testThrowsMissingNameOutsideTaskWorktree() throws {
        XCTAssertThrowsError(try TaskArgumentResolver.resolve(
            explicit: nil,
            current: nil
        )) { error in
            guard case VibeChardError.missingArgument(let name) = error else {
                return XCTFail("expected missingArgument, got \(error)")
            }
            XCTAssertEqual(name, "<name>")
        }
    }
}