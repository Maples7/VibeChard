import Foundation

/// Owns the lazy-clone semantics decided in Q8: per-task `xcrun simctl
/// clone`, only on the first build/test that needs a sim. Names follow
/// `<original> · vch[<task>]` so both vch and the user can spot the
/// clones in `Simulator.app` and `xcrun simctl list`.
public struct SimulatorService: Sendable {
    public let workspace: Workspace
    public let fs: FileSystem
    public let simctl: SimctlClient

    public init(
        workspace: Workspace,
        simctl: SimctlClient,
        fs: FileSystem = DiskFileSystem()
    ) {
        self.workspace = workspace
        self.simctl = simctl
        self.fs = fs
    }

    /// Resolved clone identity used for this build/test.
    public struct Resolved: Equatable, Sendable {
        public let udid: String
        public let name: String
        /// True when `ensureClone` performed a clone in this call.
        /// Helps the CLI emit a one-line "cloning ..." message.
        public let createdNow: Bool
    }

    /// Lazy-clone the simulator for `task`.
    ///
    /// - If `state.json.simulator` is already populated, returns it
    ///   (after sanity-checking that `requestedDevice` either matches
    ///   or is nil — caller can opt into reuse without specifying
    ///   `--device` again).
    /// - Otherwise, if `requestedDevice` is nil, returns nil so the
    ///   caller invokes xcodebuild without a `-destination` flag (M4
    ///   behavior).
    /// - Otherwise, picks the newest available template named
    ///   `requestedDevice`, runs `xcrun simctl clone`, persists
    ///   `simulator{cloneUDID, sourceUDID, name}` into state.json,
    ///   and returns it.
    public func ensureClone(
        task: TaskName,
        requestedDevice: String?
    ) throws -> Resolved? {
        let statePath = workspace.statePath(for: task)
        guard fs.fileExists(at: statePath) else {
            throw VibeChardError.stateFileCorrupt(
                path: statePath,
                underlying: "missing — run `vch repair`"
            )
        }
        let data = try fs.readFile(at: statePath)
        var state = try TaskState.parse(data)

        if let existing = state.simulator {
            if let requested = requestedDevice, requested != existing.name {
                throw VibeChardError.simulatorAlreadyBound(
                    taskName: task.raw,
                    currentName: existing.name,
                    requestedName: requested
                )
            }
            return Resolved(udid: existing.cloneUDID, name: existing.name,
                            createdNow: false)
        }

        guard let requested = requestedDevice, !requested.isEmpty else {
            return nil
        }

        let template = try pickNewestTemplate(name: requested)
        let cloneName = cloneDisplayName(originalName: template.name, task: task)
        let newUDID = try simctl.clone(sourceUDID: template.udid, newName: cloneName)

        let record = TaskState.SimulatorRecord(
            cloneUDID: newUDID,
            sourceUDID: template.udid,
            name: cloneName
        )
        state.simulator = record
        try fs.writeFileAtomic(state.jsonData(), to: statePath)

        return Resolved(udid: record.cloneUDID, name: record.name, createdNow: true)
    }

    /// `xcrun simctl bootstatus -b` — boots the device if shutdown,
    /// then waits for boot completion. Idempotent.
    public func bootIfNeeded(udid: String) throws {
        try simctl.bootstatusBoot(udid: udid)
    }

    /// Best-effort delete used by `vch remove`. Returns true if the
    /// clone was successfully deleted (or never existed).
    @discardableResult
    public func deleteClone(udid: String) throws -> Bool {
        try simctl.delete(udid: udid)
        return true
    }

    // MARK: - selection

    /// Pick the newest available template whose name exactly matches.
    /// "Newest" = highest iOS runtime version (then arbitrary stable
    /// tiebreak by UDID). Templates with `isAvailable == false` are
    /// filtered out.
    func pickNewestTemplate(name: String) throws -> SimDevice {
        let all = try simctl.availableDevices()
        let matches = all.filter { $0.isAvailable && $0.name == name }
        guard !matches.isEmpty else {
            throw VibeChardError.simulatorTemplateNotFound(name: name)
        }
        let sorted = matches.sorted { lhs, rhs in
            switch (lhs.runtimeVersion, rhs.runtimeVersion) {
            case let (l?, r?):
                if l != r { return l > r }
                return lhs.udid < rhs.udid
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.udid < rhs.udid
            }
        }
        return sorted.first!
    }

    /// `<original> · vch[<task>]` — the middle dot (U+00B7) is a
    /// pre-existing convention from Apple's Simulator app naming.
    /// Capped at 255 chars (HFS+/APFS limit) defensively.
    func cloneDisplayName(originalName: String, task: TaskName) -> String {
        let raw = "\(originalName) · vch[\(task.raw)]"
        if raw.count <= 255 { return raw }
        return String(raw.prefix(255))
    }
}
