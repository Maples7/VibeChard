import XCTest
@testable import VibeChardCore

final class DoctorServiceTests: XCTestCase {

    private let mainRepo = "/repos/Demo"

    /// Build a fully-wired `DoctorService` against in-memory fakes.
    /// Tasks listed in `seed` get a worktree dir, a state.json with an
    /// optional simulator binding, and a corresponding fake `git
    /// worktree` entry.
    private func makeService(
        seed: [(taskName: String, simulator: TaskState.SimulatorRecord?)] = [],
        simctlDevices: [SimDevice] = [],
        corruptStateFor: Set<String> = [],
        missingStateFor: Set<String> = []
    ) -> (DoctorService, InMemoryFileSystem, FakeGitClient, FakeSimctl) {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        let git = FakeGitClient()
        // Main worktree entry (always present for git).
        git.entries.append(WorktreeEntry(path: mainRepo, branch: "master"))
        for (raw, sim) in seed {
            let task = try! TaskName(raw)
            let wt = workspace.worktreePath(for: task)
            fs.seedDirectory(wt)
            fs.seedDirectory(workspace.vchDir(for: task))
            git.entries.append(WorktreeEntry(path: wt, branch: "agent/\(raw)"))
            if missingStateFor.contains(raw) { continue }
            if corruptStateFor.contains(raw) {
                fs.seedFile(workspace.statePath(for: task),
                            data: Data("{ not json".utf8))
                continue
            }
            var state = TaskState(
                name: raw, branch: "agent/\(raw)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                baseRef: "deadbee"
            )
            state.simulator = sim
            fs.seedFile(workspace.statePath(for: task),
                        data: try! state.jsonData())
        }
        let simctl = FakeSimctl()
        simctl.devices = simctlDevices
        let svc = DoctorService(
            workspace: workspace, git: git, simctl: simctl, fs: fs
        )
        return (svc, fs, git, simctl)
    }

    private func dev(_ udid: String, _ name: String,
                     available: Bool = true, state: String? = "Shutdown") -> SimDevice {
        SimDevice(
            udid: udid, name: name,
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            runtimeVersion: .init(major: 26, minor: 4),
            isAvailable: available,
            state: state
        )
    }

    // MARK: - clean diagnose

    func testDiagnoseReportsNothingOnHappyPath() throws {
        let (svc, _, git, _) = makeService(
            seed: [
                ("alpha", .init(cloneUDID: "C-1", sourceUDID: "S-1",
                                 name: "iPhone 16 · vch[alpha]")),
            ],
            simctlDevices: [
                dev("C-1", "iPhone 16 · vch[alpha]"),
                dev("USER-1", "iPhone 16"), // user's own, no marker
            ]
        )
        let report = try svc.diagnose()

        XCTAssertEqual(git.pruneCalls, 1)
        XCTAssertTrue(report.worktreePruneRan)
        XCTAssertFalse(report.prunedStaleEntries)
        XCTAssertEqual(report.checkedTasks, ["alpha"])
        XCTAssertTrue(report.stateProblems.isEmpty)
        XCTAssertTrue(report.orphanClones.isEmpty)
        XCTAssertTrue(report.staleBindings.isEmpty)
        XCTAssertFalse(report.hasFindings)
    }

    func testDiagnoseIncludesAdoptedWorktreeWithArbitraryPath() throws {
        let (svc, fs, git, _) = makeService()
        let adoptedPath = "/repos/codex-session"
        fs.seedDirectory(adoptedPath)
        git.entries.append(WorktreeEntry(path: adoptedPath, branch: "feature/codex"))
        let state = TaskState(
            name: "codex-task",
            branch: "feature/codex",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "abc1234",
            worktreeOwnership: .adopted
        )
        fs.seedFile(
            "\(adoptedPath)/.vch/state.json",
            data: try state.jsonData()
        )

        let report = try svc.diagnose()

        XCTAssertEqual(report.checkedTasks, ["codex-task"])
        XCTAssertTrue(report.stateProblems.isEmpty)
    }

    // MARK: - orphan clones

    func testDiagnoseDetectsOrphanCloneFromKeepSim() throws {
        // `alpha` has a state binding to C-1; ORPHAN-1 is a vch-named
        // clone with no state pointing to it (e.g. left over after
        // `vch remove --keep-sim`).
        let (svc, _, _, _) = makeService(
            seed: [
                ("alpha", .init(cloneUDID: "C-1", sourceUDID: "S-1",
                                 name: "iPhone 16 · vch[alpha]")),
            ],
            simctlDevices: [
                dev("C-1", "iPhone 16 · vch[alpha]"),
                dev("ORPHAN-1", "iPhone 16 · vch[old-task]"),
            ]
        )
        let report = try svc.diagnose()
        XCTAssertEqual(report.orphanClones.map(\.udid), ["ORPHAN-1"])
        XCTAssertTrue(report.staleBindings.isEmpty)
        XCTAssertTrue(report.hasFindings)
    }

    // #29: orphan detection recognizes BOTH the v0.3.0+ hyphen suffix
    // and the pre-v0.3.0 middle-dot bracket suffix in the same sweep.
    func testDiagnoseDetectsOrphansAcrossLegacyAndModernNaming() throws {
        let (svc, _, _, _) = makeService(
            seed: [
                ("alpha", .init(cloneUDID: "C-1", sourceUDID: "S-1",
                                 name: "iPhone 16-vch-alpha")),
            ],
            simctlDevices: [
                dev("C-1", "iPhone 16-vch-alpha"),
                dev("ORPHAN-NEW", "iPhone 16-vch-gone-modern"),
                dev("ORPHAN-OLD", "iPhone 16 · vch[gone-legacy]"),
                dev("USER-A", "iPhone 16"), // user device, no marker
            ]
        )
        let report = try svc.diagnose()
        XCTAssertEqual(report.orphanClones.map(\.udid).sorted(),
                       ["ORPHAN-NEW", "ORPHAN-OLD"])
        XCTAssertTrue(report.staleBindings.isEmpty)
    }

    func testDiagnoseDoesNotFlagUserDevicesWithoutMarker() throws {
        // None of these have ` · vch[`; they're user devices.
        let (svc, _, _, _) = makeService(
            seed: [
                ("alpha", .init(cloneUDID: "C-1", sourceUDID: "S-1",
                                 name: "iPhone 16 · vch[alpha]")),
            ],
            simctlDevices: [
                dev("C-1", "iPhone 16 · vch[alpha]"),
                dev("USER-A", "iPhone 16"),
                dev("USER-B", "iPhone 17 Pro"),
            ]
        )
        let report = try svc.diagnose()
        XCTAssertTrue(report.orphanClones.isEmpty)
    }

    // MARK: - stale bindings

    func testDiagnoseDoesNotClaimWorktreePruneMutatedState() throws {
        let (svc, _, git, _) = makeService()

        let report = try svc.diagnose()

        XCTAssertEqual(git.pruneCalls, 1)
        XCTAssertTrue(report.worktreePruneRan)
        XCTAssertFalse(report.prunedStaleEntries)
    }

    func testDiagnoseDetectsStaleBindingWhenSimGone() throws {
        // `alpha` points at C-GONE but simctl no longer lists it.
        let (svc, _, _, _) = makeService(
            seed: [
                ("alpha", .init(cloneUDID: "C-GONE", sourceUDID: "S-1",
                                 name: "iPhone 16 · vch[alpha]")),
            ],
            simctlDevices: [
                dev("USER-A", "iPhone 16"),
            ]
        )
        let report = try svc.diagnose()
        XCTAssertEqual(report.staleBindings.count, 1)
        XCTAssertEqual(report.staleBindings.first?.taskName, "alpha")
        XCTAssertEqual(report.staleBindings.first?.cloneUDID, "C-GONE")
        XCTAssertTrue(report.orphanClones.isEmpty)
    }

    // MARK: - state problems

    func testDiagnoseSurfacesMissingStateFile() throws {
        let (svc, _, _, _) = makeService(
            seed: [("alpha", nil)],
            missingStateFor: ["alpha"]
        )
        let report = try svc.diagnose()
        XCTAssertEqual(report.stateProblems.count, 1)
        XCTAssertTrue(report.stateProblems[0].contains("missing"))
    }

    func testDiagnoseSurfacesCorruptStateFile() throws {
        let (svc, _, _, _) = makeService(
            seed: [("alpha", nil)],
            corruptStateFor: ["alpha"]
        )
        let report = try svc.diagnose()
        XCTAssertEqual(report.stateProblems.count, 1)
        XCTAssertTrue(report.stateProblems[0].hasPrefix("alpha:"))
    }

    // MARK: - simctl unavailable

    func testDiagnoseSurfacesSimctlFailureAsStateProblem() throws {
        let (svc, _, _, simctl) = makeService(
            seed: [("alpha", nil)]
        )
        simctl.allThrows = .externalCommandFailed(
            cmd: "xcrun simctl list devices --json",
            exitCode: 127,
            stderr: "command not found"
        )
        let report = try svc.diagnose()
        XCTAssertEqual(report.stateProblems.count, 1)
        XCTAssertTrue(report.stateProblems[0].contains("simctl unavailable"))
        XCTAssertTrue(report.orphanClones.isEmpty)
        XCTAssertTrue(report.staleBindings.isEmpty)
    }

    // MARK: - multi-binding (#99)

    /// Re-seed `state.json` for a task with the multi-binding shape
    /// (`simulators: [...]` + legacy mirror). The base seed helper
    /// only knows the singular `simulator` field, so we overwrite
    /// the file after `makeService` lays it down.
    private func reseedMultiBinding(
        fs: InMemoryFileSystem,
        workspace: Workspace,
        taskName: String,
        bindings: [TaskState.SimulatorRecord]
    ) throws {
        let task = try TaskName(taskName)
        var state = TaskState(
            name: taskName, branch: "agent/\(taskName)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbee"
        )
        state.setSimulators(bindings)
        fs.seedFile(workspace.statePath(for: task),
                    data: try state.jsonData())
    }

    /// A task with two recorded bindings (iOS + watchOS) must not
    /// surface EITHER clone as orphan when both UDIDs are present in
    /// simctl. Pre-#99 this code only checked `state.simulator` (a
    /// single field), so the second binding would be mis-classified
    /// and `vch doctor --clean` would happily delete a live user
    /// clone. This test pins the multi-binding aware orphan scan.
    func testDiagnoseDoesNotFlagAnyBindingOfMultiBindingTaskAsOrphan() throws {
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let (svc, fs, _, _) = makeService(
            seed: [("alpha", nil)],
            simctlDevices: [
                dev("IOS-CLONE", "iPhone 16-vch-alpha"),
                dev("WATCH-CLONE", "Apple Watch Series 10-vch-alpha"),
            ]
        )
        try reseedMultiBinding(
            fs: fs, workspace: workspace, taskName: "alpha",
            bindings: [
                .init(cloneUDID: "IOS-CLONE", sourceUDID: "IOS-SRC",
                      name: "iPhone 16-vch-alpha"),
                .init(cloneUDID: "WATCH-CLONE", sourceUDID: "WATCH-SRC",
                      name: "Apple Watch Series 10-vch-alpha"),
            ]
        )

        let report = try svc.diagnose()

        XCTAssertTrue(
            report.orphanClones.isEmpty,
            "Every recorded binding must be tracked; the watch clone is NOT an orphan: \(report.orphanClones.map(\.name))"
        )
        XCTAssertTrue(report.staleBindings.isEmpty)
    }

    /// If a task records two bindings but only one device still
    /// exists in simctl, the missing one must show up as a
    /// `staleBinding` (not as an orphan — orphans are out-of-band
    /// clones, stale bindings are tasks whose recorded UDID is gone).
    /// The other binding stays clean.
    func testDiagnoseFlagsOneMissingBindingAsStaleAndLeavesOtherClean() throws {
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let (svc, fs, _, _) = makeService(
            seed: [("alpha", nil)],
            simctlDevices: [
                dev("IOS-CLONE", "iPhone 16-vch-alpha"),
                // WATCH-CLONE deleted out-of-band — not in simctl.
            ]
        )
        try reseedMultiBinding(
            fs: fs, workspace: workspace, taskName: "alpha",
            bindings: [
                .init(cloneUDID: "IOS-CLONE", sourceUDID: "IOS-SRC",
                      name: "iPhone 16-vch-alpha"),
                .init(cloneUDID: "WATCH-CLONE", sourceUDID: "WATCH-SRC",
                      name: "Apple Watch Series 10-vch-alpha"),
            ]
        )

        let report = try svc.diagnose()

        XCTAssertTrue(report.orphanClones.isEmpty,
                      "iOS clone is bound; it must NOT be an orphan")
        XCTAssertEqual(report.staleBindings.count, 1)
        XCTAssertEqual(report.staleBindings[0].cloneUDID, "WATCH-CLONE")
        XCTAssertEqual(report.staleBindings[0].taskName, "alpha")
    }

    // MARK: - clean

    func testCleanDeletesOrphansBestEffort() throws {
        let (svc, _, _, simctl) = makeService(
            seed: [
                ("alpha", .init(cloneUDID: "C-1", sourceUDID: "S-1",
                                 name: "iPhone 16 · vch[alpha]")),
            ],
            simctlDevices: [
                dev("C-1", "iPhone 16 · vch[alpha]"),
                dev("ORPHAN-1", "iPhone 16 · vch[gone1]"),
                dev("ORPHAN-2", "iPhone 16 · vch[gone2]"),
            ]
        )
        let report = try svc.diagnose()
        let clean = svc.clean(report)
        XCTAssertEqual(clean.deletedClones.sorted(),
                       ["iPhone 16 · vch[gone1]", "iPhone 16 · vch[gone2]"])
        XCTAssertTrue(clean.failedDeletes.isEmpty)
        XCTAssertEqual(simctl.deleteCalls.sorted(),
                       ["ORPHAN-1", "ORPHAN-2"])
    }

    func testCleanRecordsFailures() throws {
        let (svc, _, _, simctl) = makeService(
            seed: [],
            simctlDevices: [
                dev("ORPHAN-1", "iPhone 16 · vch[gone]"),
            ]
        )
        simctl.deleteThrows = .externalCommandFailed(
            cmd: "simctl delete ORPHAN-1",
            exitCode: 1,
            stderr: "permission denied"
        )
        let report = try svc.diagnose()
        let clean = svc.clean(report)
        XCTAssertTrue(clean.deletedClones.isEmpty)
        XCTAssertEqual(clean.failedDeletes.count, 1)
        XCTAssertEqual(clean.failedDeletes.first?.name, "iPhone 16 · vch[gone]")
    }

    // MARK: - warm templates (#47)

    /// Warm-template devices must NEVER be classified as orphan clones
    /// — the user owns their lifecycle. Orphan-clone scanning is what
    /// triggers `vch doctor --clean` deletes; misclassification would
    /// destroy 30+ s of priming work without consent.
    func testDiagnoseExcludesWarmTemplatesFromOrphanClones() throws {
        let (svc, _, _, _) = makeService(
            seed: [
                ("alpha", .init(cloneUDID: "C-1", sourceUDID: "S-1",
                                 name: "iPhone 16-vch-alpha")),
            ],
            simctlDevices: [
                dev("C-1", "iPhone 16-vch-alpha"),
                dev("WARM", "vch-warm[iPhone 16:iOS 26.4]"),
            ]
        )
        let report = try svc.diagnose()
        XCTAssertTrue(report.orphanClones.isEmpty)
    }

    /// Healthy warm templates surface in the report but do NOT trigger
    /// `hasFindings` (so `--exit-code` stays 0 in CI).
    func testDiagnoseListsHealthyWarmTemplatesWithoutFindings() throws {
        let (svc, _, _, _) = makeService(
            simctlDevices: [
                dev("WARM", "vch-warm[iPhone 16:iOS 26.4]"),
            ]
        )
        let report = try svc.diagnose()
        XCTAssertEqual(report.warmTemplates.map(\.udid), ["WARM"])
        XCTAssertEqual(report.warmTemplates.first?.health, .ok)
        XCTAssertFalse(report.hasFindings)
    }

    /// An unhealthy warm template (booted, stale, malformed) should
    /// flip `hasFindings` so users notice on their next `vch doctor`
    /// run.
    func testDiagnoseFlagsUnhealthyWarmTemplate() throws {
        let (svc, _, _, _) = makeService(
            simctlDevices: [
                dev("BOOTED-WARM", "vch-warm[iPhone 16:iOS 26.4]",
                    state: "Booted"),
            ]
        )
        let report = try svc.diagnose()
        XCTAssertEqual(report.warmTemplates.first?.health, .booted)
        XCTAssertTrue(report.hasFindings)
    }
}
