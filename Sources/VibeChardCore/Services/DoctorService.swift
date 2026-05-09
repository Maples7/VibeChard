import Foundation

/// `vch doctor` — sweeps the workspace for the kinds of orphans that
/// accumulate when builds, removes, or simctl interactions are
/// interrupted. Wraps `TaskService.repair()` (worktree prune +
/// state.json sanity), then layers simulator-specific checks on top.
///
/// Detects:
/// - **Orphan vch simulator clones** — devices in `simctl list` whose
///   name carries the vch suffix (`-vch-<task>` for v0.3.0+ clones, or
///   the pre-v0.3.0 `· vch[<task>]` form) but whose UDID isn't bound
///   to any live task. Common cause: `vch remove --keep-sim` left
///   them, or removal happened while simctl was offline. `--clean`
///   deletes these.
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

    /// Markers every vch-managed clone has in its name. We do not
    /// look at the prefix because the user's original device name may
    /// contain anything; the suffixes below are our canonical stamps.
    ///
    /// - `-vch-` is the v0.3.0+ scheme (`<original>-vch-<task>`).
    /// - `· vch[` is the pre-v0.3.0 scheme
    ///   (`<original> · vch[<task>]`); kept so existing clones still
    ///   surface as orphans when their tasks vanish.
    ///
    /// **Warm templates are deliberately excluded** — their lifetime
    /// is decoupled from any task (#47, AGENTS.md hard rule #9). They
    /// are surfaced in `Report.warmTemplates` as informational rows and
    /// `clean()` never deletes them.
    public static let cloneNameMarkers: [String] = ["-vch-", "· vch["]

    /// Pre-v0.3.0 single-marker accessor. Retained as the first entry
    /// of `cloneNameMarkers` for any external callers that might still
    /// reference it; new code should use `cloneNameMarkers`.
    @available(*, deprecated, renamed: "cloneNameMarkers")
    public static var cloneNameMarker: String { cloneNameMarkers.last ?? "-vch-" }

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
        /// Vch-managed warm templates discovered via
        /// `simctl list devices --json`. Surfaced as an informational
        /// section — `clean()` never touches these. Templates flagged
        /// `stale` / `booted` / `malformed` are listed so users can
        /// decide whether to `vch sim warm-template remove` and
        /// recreate. (#47)
        public var warmTemplates: [WarmTemplateRecord]

        public init(
            prunedStaleEntries: Bool = false,
            checkedTasks: [String] = [],
            stateProblems: [String] = [],
            orphanClones: [SimDevice] = [],
            staleBindings: [StaleBinding] = [],
            warmTemplates: [WarmTemplateRecord] = []
        ) {
            self.prunedStaleEntries = prunedStaleEntries
            self.checkedTasks = checkedTasks
            self.stateProblems = stateProblems
            self.orphanClones = orphanClones
            self.staleBindings = staleBindings
            self.warmTemplates = warmTemplates
        }

        /// Anything for the user to act on?
        public var hasFindings: Bool {
            // A merely-present warm template is informational, not a
            // finding. Unhealthy warm templates *are* findings the
            // user can act on; we surface them via the same exit
            // signal as any other doctor finding.
            !stateProblems.isEmpty
                || !orphanClones.isEmpty
                || !staleBindings.isEmpty
                || warmTemplates.contains(where: { $0.health != .ok })
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

            let statePath = PathOps.join(entry.path, Workspace.stateJsonRelativePath)
            guard fs.fileExists(at: statePath) else {
                report.stateProblems.append("\(raw): missing \(Workspace.stateJsonRelativePath)")
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

        // Orphans: devices whose name carries either marker but whose
        // UDID isn't bound to any live task. Both the v0.3.0 hyphen
        // suffix and the pre-v0.3.0 middle-dot bracket suffix are
        // recognized so users mid-upgrade aren't stranded. Warm
        // templates carry the `-vch-` substring inside their
        // `vch-warm[...]` name (literally `vch-warm`), so explicitly
        // exclude them — they are not orphans, regardless of whether
        // they're bound to a task.
        let liveUDIDs = Set(boundByUDID.keys)
        let vchNamed = allDevices.filter { device in
            if WarmTemplateName.isWarmTemplateName(device.name) { return false }
            return Self.cloneNameMarkers.contains(where: { device.name.contains($0) })
        }
        report.orphanClones = vchNamed
            .filter { !liveUDIDs.contains($0.udid) }
            .sorted { $0.name < $1.name }

        // Stale bindings: a task points at a UDID simctl no longer has.
        let knownUDIDs = Set(allDevices.map(\.udid))
        report.staleBindings = boundByUDID.values
            .filter { !knownUDIDs.contains($0.cloneUDID) }
            .sorted { $0.taskName < $1.taskName }

        // Warm templates (#47): listed unconditionally, never
        // auto-cleaned. We reuse `SimulatorService.listWarmTemplates`
        // so the parsing + health classification stays in one place.
        do {
            let sim = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)
            report.warmTemplates = try sim.listWarmTemplates()
        } catch let err as VibeChardError {
            report.stateProblems.append("warm-templates listing failed: \(err)")
        } catch {
            report.stateProblems.append("warm-templates listing failed: \(error)")
        }

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
