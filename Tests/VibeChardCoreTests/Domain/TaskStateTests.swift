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

    // MARK: - baseBranch (#7)

    func testParsesLegacyStateWithoutBaseBranch() throws {
        // state.json files written by vch ≤ v0.1.x lack the
        // `baseBranch` field. They must still decode cleanly so the
        // upgrade path is silent — `vch land` will fall back to the
        // current main-worktree branch when this is nil.
        let json = """
        {
          "schemaVersion": 1,
          "name": "foo",
          "branch": "agent/foo",
          "createdAt": "2024-01-01T00:00:00Z",
          "baseRef": "abc1234"
        }
        """
        let state = try TaskState.parse(Data(json.utf8))
        XCTAssertNil(state.baseBranch)
        XCTAssertEqual(state.name, "foo")
    }

    func testRoundtripsBaseBranch() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = TaskState(
            name: "foo",
            branch: "agent/foo",
            createdAt: now,
            baseRef: "abc1234",
            baseBranch: "develop"
        )
        let restored = try TaskState.parse(try original.jsonData())
        XCTAssertEqual(restored.baseBranch, "develop")
    }

    func testRoundtripsLastSync() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        let original = TaskState(
            name: "foo",
            branch: "agent/foo",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "abc1234",
            baseBranch: "origin/main",
            lastSync: TaskState.SyncRecord(
                finishedAt: now,
                baseSHA: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                baseLabel: "origin/main",
                strategy: "rebase",
                appliedCommits: 3,
                durationSeconds: 0.512
            )
        )
        let restored = try TaskState.parse(try original.jsonData())
        let sync = try XCTUnwrap(restored.lastSync)
        XCTAssertEqual(sync.finishedAt.timeIntervalSince1970, 1_700_000_500)
        XCTAssertEqual(sync.baseSHA, "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
        XCTAssertEqual(sync.baseLabel, "origin/main")
        XCTAssertEqual(sync.strategy, "rebase")
        XCTAssertEqual(sync.appliedCommits, 3)
        XCTAssertEqual(sync.durationSeconds, 0.512, accuracy: 1e-6)
    }

    func testParsesStateWithoutLastSync() throws {
        // Schema-stable: state.json files written before #25 must still
        // parse without `lastSync`.
        let json = """
        {
          "schemaVersion": 1,
          "name": "foo",
          "branch": "agent/foo",
          "createdAt": "2024-01-01T00:00:00Z",
          "baseRef": "abc1234"
        }
        """
        let state = try TaskState.parse(Data(json.utf8))
        XCTAssertNil(state.lastSync)
    }
}
