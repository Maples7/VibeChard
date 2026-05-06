import Foundation

/// `vch doctor` — sweeps the workspace for the kinds of orphans that
/// accumulate when builds, removes, or simctl interactions are
/// interrupted. Wraps `TaskService.repair()` (worktree prune +
/// state.json sanity), then layers simulator-specific checks on top.
///
/// Detects:
/// - **Orphan vch[*] simulator clones** — devices in `simctl list`
///   whose name looks like a vch clone (`· vch[<task>]`) but whose
///   UDID isn't bound to any live task. Common cause:
///   `vch remove --keep-sim` left them, or removal happened while
///   simctl was offline. `--clean` deletes these.
/// - **Stale simulator bindings** — a task's `state.simulator.cloneUDID`
///   doesn't exist in `simctl list` anymore (someone deleted the
///   device out-of-band). `--clean` does NOT auto-fix these — the
///   right answer is `vch repair` or a manual `vch sim clone`.
/// - **State.json problems** — same set as `vch repair` would surface.
public struct DoctorService: Sendable {
    public let workspace: Workspace
    public let git: GitClient
    public let fs: FileSystem
    public let simctl: SimctlClient

    public init(
        workspace: Workspace,
        git: GitClient,
        simctl: SimctlClient,
        fs: FileSystem = DiskFileSystem()
    ) {
        self.workspace = workspace
        self.git = git
        self.simctl = simctl
        self.fs = fs
    }

    /// Marker every vch-managed clone has in its name. We do not look
    /// at the prefix because the user's original device name may
    /// contain anything; the `· vch[<task>]` suffix is our canonical
    /// stamp.
    public static let cloneNameMarker = "· vch["

    public struct StaleBinding: Equatable, Sendable {
        public let taskName: String
        public let cloneUDID: String
        public let cloneName: String
    }

    public struct Report: Equatable, Sendable {
        public var prunedStaleEntries: Bool
        public var checkedTasks: [String]
        public var stateProblems: [String]
        public var orphanClones: [SimDevice]
        public var staleBindings: [StaleBinding]

        public init(
            prunedStaleEntries: Bool = false,
            checkedTasks: [String] = [],
            stateProblems: [String] = [],
            orphanClones: [SimDevice] = [],
            staleBindings: [StaleBinding] = []
        ) {
            self.prunedStaleEntries = prunedStaleEntries
            self.checkedTasks = checkedTasks
            self.stateProblems = stateProblems
            self.orphanClones = orphanClones
            self.staleBindings = staleBindings
        }

        /// Anything for the user to act on?
        public var hasFindings: Bool {
            !stateProblems.isEmpty
                || !orphanClones.isEmpty
                || !staleBindings.isEmpty
        }
    }

    /// Read-only sweep. Never deletes anything.
    public func diagnose() throws -> Report {
        var report = Report()

        // Worktree-level checks (delegates to TaskService.repair() shape).
        try git.worktreePrune(repoCwd: workspace.mainWorktreePath)
        report.prunedStaleEntries = true

        // Walk live tasks; collect bound UDIDs and surface state problems.
        var boundByUDID: [String: StaleBinding] = [:]
        let entries = try git.worktreeList(repoCwd: workspace.mainWorktreePath)
        for entry in entries {
            if entry.path == workspace.mainWorktreePath { continue }
            guard let raw = workspace.taskNameRaw(forWorktreePath: entry.path) else { continue }
            report.checkedTasks.append(raw)

            let statePath = "\(entry.path)/.vch/state.json"
            guard fs.fileExists(at: statePath) else {
                report.stateProblems.append("\(raw): missing .vch/state.json")
                continue
            }
            do {
                let data = try fs.readFile(at: statePath)
                let state = try TaskState.parse(data)
                if let sim = state.simulator {
                    boundByUDID[sim.cloneUDID] = StaleBinding(
                        taskName: raw,
                        cloneUDID: sim.cloneUDID,
                        cloneName: sim.name
                    )
                }
            } catch let err as VibeChardError {
                report.stateProblems.append("\(raw): \(err)")
            } catch {
                report.stateProblems.append("\(raw): \(error)")
            }
        }

        // Now query simctl once and reconcile.
        let allDevices: [SimDevice]
        do {
            allDevices = try simctl.allDevices()
        } catch let err as VibeChardError {
            // simctl unreachable is itself a finding — surface it.
            report.stateProblems.append("simctl unavailable: \(err)")
            return report
        }

        // Orphans: devices whose name carries our marker but whose
        // UDID isn't bound to any live task.
        let liveUDIDs = Set(boundByUDID.keys)
        let vchNamed = allDevices.filter { $0.name.contains(Self.cloneNameMarker) }
        report.orphanClones = vchNamed
            .filter { !liveUDIDs.contains($0.udid) }
            .sorted { $0.name < $1.name }

        // Stale bindings: a task points at a UDID simctl no longer has.
        let knownUDIDs = Set(allDevices.map(\.udid))
        report.staleBindings = boundByUDID.values
            .filter { !knownUDIDs.contains($0.cloneUDID) }
            .sorted { $0.taskName < $1.taskName }

        return report
    }

    public struct CleanReport: Equatable, Sendable {
        public var deletedClones: [String]   // names
        public var failedDeletes: [(name: String, error: String)]

        public init(
            deletedClones: [String] = [],
            failedDeletes: [(name: String, error: String)] = []
        ) {
            self.deletedClones = deletedClones
            self.failedDeletes = failedDeletes
        }

        public static func == (lhs: CleanReport, rhs: CleanReport) -> Bool {
            guard lhs.deletedClones == rhs.deletedClones else { return false }
            guard lhs.failedDeletes.count == rhs.failedDeletes.count else { return false }
            for (a, b) in zip(lhs.failedDeletes, rhs.failedDeletes) {
                if a.name != b.name || a.error != b.error { return false }
            }
            return true
        }
    }

    /// Best-effort delete each orphan clone. Stale bindings are NOT
    /// auto-fixed — that's the user's call.
    public func clean(_ report: Report) -> CleanReport {
        var clean = CleanReport()
        for orphan in report.orphanClones {
            do {
                try simctl.delete(udid: orphan.udid)
                clean.deletedClones.append(orphan.name)
            } catch {
                clean.failedDeletes.append((name: orphan.name, error: "\(error)"))
            }
        }
        return clean
    }
}
