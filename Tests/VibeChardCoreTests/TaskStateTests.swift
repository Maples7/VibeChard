import XCTest
@testable import VibeChardCore

final class TaskStateTests: XCTestCase {

    func testRoundtripsMinimalState() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = TaskState(
            name: "foo",
            branch: "agent/foo",
            createdAt: now,
            baseRef: "abc1234"
        )
        let data = try original.jsonData()
        let restored = try TaskState.parse(data)
        XCTAssertEqual(restored, original)
    }

    func testRoundtripsFullyPopulatedState() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = TaskState(
            name: "foo",
            branch: "agent/foo",
            createdAt: now,
            baseRef: "abc1234",
            scheme: "BeanLedger",
            simulator: .init(cloneUDID: "uuid-clone", sourceUDID: "uuid-src", name: "iPhone 17"),
            lastBuild: .init(finishedAt: now, durationSeconds: 12.5, success: true),
            lastTest: .init(finishedAt: now, durationSeconds: 30, success: false, resultBundlePath: "/tmp/Result.xcresult"),
            lastExec: .init(command: "claude --dangerously-yes", startedAt: now, exitedAt: now, exitCode: 0)
        )
        let data = try original.jsonData()
        let restored = try TaskState.parse(data)
        XCTAssertEqual(restored, original)
    }

    func testJSONIsPrettyAndSortedKeys() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = TaskState(name: "foo", branch: "agent/foo", createdAt: now, baseRef: "abc1234")
        let data = try state.jsonData()
        let str = try XCTUnwrap(String(data: data, encoding: .utf8))
        // pretty-printed = newlines present
        XCTAssertTrue(str.contains("\n"), "expected pretty-printed JSON, got \(str)")
        // sorted keys = `baseRef` precedes `branch` alphabetically
        let baseRefIdx = try XCTUnwrap(str.range(of: "\"baseRef\""))
        let branchIdx = try XCTUnwrap(str.range(of: "\"branch\""))
        XCTAssertTrue(baseRefIdx.lowerBound < branchIdx.lowerBound)
    }

    func testRejectsWrongSchemaVersion() throws {
        let json = """
        {
          "schemaVersion": 999,
          "name": "foo",
          "branch": "agent/foo",
          "createdAt": "2024-01-01T00:00:00Z",
          "baseRef": "abc"
        }
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try TaskState.parse(data)) { error in
            guard case VibeChardError.stateSchemaMismatch(let found, let expected) = error else {
                return XCTFail("expected stateSchemaMismatch, got \(error)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(expected, 1)
        }
    }

    func testRejectsCorruptJSON() {
        let data = Data("not json".utf8)
        XCTAssertThrowsError(try TaskState.parse(data)) { error in
            guard case VibeChardError.stateFileCorrupt = error else {
                return XCTFail("expected stateFileCorrupt, got \(error)")
            }
        }
    }
}
