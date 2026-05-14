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

    func testRoundtripsAdoptedWorktreeOwnership() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = TaskState(
            name: "foo",
            branch: "feature/foo",
            createdAt: now,
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )

        let restored = try TaskState.parse(try original.jsonData())
        XCTAssertEqual(restored.worktreeOwnership, .adopted)
        XCTAssertFalse(restored.ownsGitWorktree)
    }

    func testLegacyStateDefaultsToVchOwnedWorktree() throws {
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
        XCTAssertNil(state.worktreeOwnership)
        XCTAssertTrue(state.ownsGitWorktree)
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

    // MARK: - lastTest.extraArgs (#46)

    func testParsesLegacyTestRecordWithoutExtraArgs() throws {
        // state.json files written by vch ≤ v0.3.0 lack
        // `lastTest.extraArgs`. They must still decode cleanly so
        // `vch test --rerun` can detect the legacy state and surface
        // a clean error rather than crashing on a missing key.
        let json = """
        {
          "schemaVersion": 1,
          "name": "foo",
          "branch": "agent/foo",
          "createdAt": "2024-01-01T00:00:00Z",
          "baseRef": "abc1234",
          "lastTest": {
            "finishedAt": "2024-01-01T00:00:00Z",
            "durationSeconds": 12,
            "success": true,
            "resultBundlePath": "/tmp/Result.xcresult"
          }
        }
        """
        let state = try TaskState.parse(Data(json.utf8))
        XCTAssertNotNil(state.lastTest)
        XCTAssertNil(state.lastTest?.extraArgs)
    }

    func testRoundtripsTestRecordExtraArgs() throws {
        // The whole point of the field is that it survives a write
        // → read cycle untouched, including the empty-array case
        // (which is semantically distinct from `nil`).
        let now = Date(timeIntervalSince1970: 1_700_000_300)
        let original = TaskState(
            name: "foo",
            branch: "agent/foo",
            createdAt: now,
            baseRef: "abc1234",
            lastTest: .init(
                finishedAt: now,
                durationSeconds: 12,
                success: false,
                resultBundlePath: "/tmp/R.xcresult",
                extraArgs: ["-only-testing:Tests/A/testFoo", "-quiet"]
            )
        )
        let restored = try TaskState.parse(try original.jsonData())
        XCTAssertEqual(restored.lastTest?.extraArgs,
                       ["-only-testing:Tests/A/testFoo", "-quiet"])

        let originalEmpty = TaskState(
            name: "foo",
            branch: "agent/foo",
            createdAt: now,
            baseRef: "abc1234",
            lastTest: .init(
                finishedAt: now,
                durationSeconds: 12,
                success: true,
                resultBundlePath: nil,
                extraArgs: []
            )
        )
        let restoredEmpty = try TaskState.parse(try originalEmpty.jsonData())
        XCTAssertEqual(restoredEmpty.lastTest?.extraArgs, [])
    }

    // MARK: - simulator.sourceKind (#47)

    func testRoundtripsSimulatorSourceKindWarmTemplate() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_400)
        let original = TaskState(
            name: "alpha",
            branch: "agent/alpha",
            createdAt: now,
            baseRef: "deadbee",
            simulator: .init(
                cloneUDID: "C", sourceUDID: "WARM", name: "iPhone 16-vch-alpha",
                templateName: "iPhone 16",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                sourceKind: .warmTemplate
            )
        )
        let restored = try TaskState.parse(try original.jsonData())
        XCTAssertEqual(restored.simulator?.sourceKind, .warmTemplate)
    }

    /// Legacy state.json files written by vch ≤ v0.3.0 don't carry
    /// the `sourceKind` field. They must still decode (it stays nil)
    /// — adding a required field would be a breaking schema change
    /// that strands users with existing tasks.
    func testLegacySimulatorRecordWithoutSourceKindStillDecodes() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "alpha",
          "branch": "agent/alpha",
          "createdAt": "2024-01-01T00:00:00Z",
          "baseRef": "deadbee",
          "simulator": {
            "cloneUDID": "C",
            "sourceUDID": "S",
            "name": "iPhone 16-vch-alpha",
            "templateName": "iPhone 16",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
          }
        }
        """
        let state = try TaskState.parse(Data(json.utf8))
        XCTAssertNotNil(state.simulator)
        XCTAssertNil(state.simulator?.sourceKind)
        XCTAssertEqual(state.simulator?.cloneUDID, "C")
    }

    func testSimulatorRecordDerivesRuntimeVersionAndPlatform() {
        let watch = TaskState.SimulatorRecord(
            cloneUDID: "WATCH-CLONE",
            sourceUDID: "WATCH-SRC",
            name: "Apple Watch Series 10-vch-alpha",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-5"
        )
        XCTAssertEqual(
            watch.runtimeVersion,
            SimRuntimeVersion(platform: .watchOS, major: 11, minor: 5)
        )
        XCTAssertEqual(watch.platform, .watchOS)

        let legacy = TaskState.SimulatorRecord(
            cloneUDID: "LEGACY-CLONE",
            sourceUDID: "LEGACY-SRC",
            name: "iPhone 16-vch-alpha"
        )
        XCTAssertNil(legacy.runtimeVersion)
        XCTAssertNil(legacy.platform)
    }

    // MARK: - simulators[] multi-binding schema (#99)

    /// `setSimulators` must write `simulators` AND mirror the first
    /// element back into the legacy `simulator` field, so a downgraded
    /// vch binary (or any reader pinned to the pre-#99 schema) still
    /// sees one binding instead of zero.
    func testSimulatorsListRoundtripsAndMirrorsFirstToLegacySimulator() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        var original = TaskState(
            name: "alpha",
            branch: "agent/alpha",
            createdAt: now,
            baseRef: "deadbee"
        )
        let ios = TaskState.SimulatorRecord(
            cloneUDID: "IOS-CLONE", sourceUDID: "IOS-SRC",
            name: "iPhone 16-vch-alpha",
            templateName: "iPhone 16",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
        )
        let watch = TaskState.SimulatorRecord(
            cloneUDID: "WATCH-CLONE", sourceUDID: "WATCH-SRC",
            name: "Apple Watch Series 10-vch-alpha",
            templateName: "Apple Watch Series 10",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"
        )
        original.setSimulators([ios, watch])

        let restored = try TaskState.parse(try original.jsonData())

        // Multi-binding list survived the round-trip in order.
        XCTAssertEqual(restored.simulators?.count, 2)
        XCTAssertEqual(restored.simulators?[0], ios)
        XCTAssertEqual(restored.simulators?[1], watch)

        // Legacy mirror still points at first — this is the downgrade
        // safety contract.
        XCTAssertEqual(restored.simulator, ios,
                       "legacy `simulator` must mirror first binding for downgrade safety")
        // And the canonical accessor returns the full list.
        XCTAssertEqual(restored.allSimulators, [ios, watch])
    }

    /// `setSimulators([])` must wipe BOTH the new and legacy fields
    /// so an empty state.json doesn't leave a stray ghost-binding
    /// behind. This is the contract `LandService` and `RemoveCommand`
    /// rely on after a successful multi-clone reap.
    func testSetSimulatorsEmptyClearsBothFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        var state = TaskState(
            name: "alpha",
            branch: "agent/alpha",
            createdAt: now,
            baseRef: "deadbee"
        )
        state.setSimulators([
            .init(cloneUDID: "C1", sourceUDID: "S1", name: "iPhone-1"),
            .init(cloneUDID: "C2", sourceUDID: "S2", name: "Watch-1")
        ])
        XCTAssertEqual(state.simulators?.count, 2)
        XCTAssertNotNil(state.simulator)

        state.setSimulators([])
        XCTAssertNil(state.simulators)
        XCTAssertNil(state.simulator,
                     "clearing must also drop the legacy mirror so downgraded readers see no binding")
        XCTAssertTrue(state.allSimulators.isEmpty)
    }

    /// `setSimulators` with one element must collapse cleanly: the
    /// new `simulators` field stays a single-element list AND legacy
    /// `simulator` matches. The round-trip preserves both. This is
    /// the post-#99 shape of a freshly-cloned single-binding task.
    func testSetSimulatorsWithOneRecordKeepsBothFieldsInSync() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        var state = TaskState(
            name: "alpha",
            branch: "agent/alpha",
            createdAt: now,
            baseRef: "deadbee"
        )
        let ios = TaskState.SimulatorRecord(
            cloneUDID: "IOS-CLONE", sourceUDID: "IOS-SRC",
            name: "iPhone 16-vch-alpha"
        )
        state.setSimulators([ios])

        XCTAssertEqual(state.simulators, [ios])
        XCTAssertEqual(state.simulator, ios)
        XCTAssertEqual(state.allSimulators, [ios])

        let restored = try TaskState.parse(try state.jsonData())
        XCTAssertEqual(restored.simulators, [ios])
        XCTAssertEqual(restored.simulator, ios)
    }

    /// Legacy state.json files written before #99 carry only the
    /// singular `simulator` field. `allSimulators` must promote that
    /// into a one-element list so every #99-aware consumer
    /// (LandService, DoctorService, TaskService.summarize, etc.) can
    /// treat the legacy path uniformly without a separate branch.
    func testLegacyOnlyStateDecodesIntoSingletonAllSimulators() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "alpha",
          "branch": "agent/alpha",
          "createdAt": "2024-01-01T00:00:00Z",
          "baseRef": "deadbee",
          "simulator": {
            "cloneUDID": "LEGACY-CLONE",
            "sourceUDID": "LEGACY-SRC",
            "name": "iPhone 16-vch-alpha",
            "templateName": "iPhone 16",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
          }
        }
        """
        let state = try TaskState.parse(Data(json.utf8))
        XCTAssertNil(state.simulators,
                     "legacy state must NOT auto-populate `simulators` at decode time")
        XCTAssertEqual(state.allSimulators.count, 1)
        XCTAssertEqual(state.allSimulators[0].cloneUDID, "LEGACY-CLONE")
    }

    /// State.json files without any simulator binding (a fresh
    /// `vch new` with no `vch build` yet) must decode cleanly and
    /// surface an empty `allSimulators`.
    func testParsesStateWithoutAnySimulatorField() throws {
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
        XCTAssertNil(state.simulators)
        XCTAssertNil(state.simulator)
        XCTAssertTrue(state.allSimulators.isEmpty)
    }
}
