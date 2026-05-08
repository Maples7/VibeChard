import Foundation

/// Owns the lazy-clone semantics decided in Q8: per-task `xcrun simctl
/// clone`, only on the first build/test that needs a sim. Names follow
/// `<original>-vch-<task>` so both vch and the user can spot the
/// clones in `Simulator.app` and `xcrun simctl list`. (The pre-v0.3.0
/// scheme was `<original> · vch[<task>]`; legacy clones are still
/// recognized via dual-prefix scanning — UDID is the source of truth.)
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
        /// Parsed iOS version of the clone's runtime, surfaced into
        /// the `vch build` / `vch test` log so the user can spot
        /// silent runtime drift (#11). nil for legacy state
        /// (vch ≤ v0.1.x) or non-iOS runtimes.
        public let runtime: SimRuntimeVersion?

        public init(udid: String, name: String, createdNow: Bool,
                    runtime: SimRuntimeVersion? = nil) {
            self.udid = udid
            self.name = name
            self.createdNow = createdNow
            self.runtime = runtime
        }
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
    ///   `requestedDevice` (filtered by `requestedRuntime` when set,
    ///   #11), runs `xcrun simctl clone`, persists
    ///   `simulator{cloneUDID, sourceUDID, name}` into state.json,
    ///   and returns it.
    public func ensureClone(
        task: TaskName,
        requestedDevice: String?,
        requestedRuntime: String? = nil
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
            if let requested = requestedDevice {
                // #4: previously this compared `requested` against
                // `existing.name`, which is the *clone display name*
                // and therefore never matched the user's
                // `--device 'iPhone 16'`. Compare against the persisted
                // template name instead, falling back to a suffix-strip
                // on legacy state written by vch ≤ v0.1.x (no
                // `templateName` field). Both the v0.3.0 hyphen suffix
                // (`-vch-<task>`) and the pre-v0.3.0 middle-dot suffix
                // (` · vch[<task>]`) are recognized.
                let bound = existing.templateName
                    ?? Self.stripCloneSuffix(from: existing.name, task: task)
                if bound != requested {
                    throw VibeChardError.simulatorAlreadyBound(
                        taskName: task.raw,
                        currentName: existing.name,
                        requestedName: requested
                    )
                }
            }
            // #11(b): if the user *also* passed --runtime, refuse to
            // reuse a clone whose persisted runtime doesn't match.
            if let req = requestedRuntime,
               let target = parseRuntimeRequest(req),
               let bound = existing.runtimeIdentifier
                    .flatMap({ SimRuntimeVersion.parse(runtimeIdentifier: $0) }),
               bound != target {
                throw VibeChardError.simulatorAlreadyBound(
                    taskName: task.raw,
                    currentName: "\(existing.name) (runtime iOS \(bound.major).\(bound.minor))",
                    requestedName: "\(requestedDevice ?? existing.templateName ?? existing.name) (runtime iOS \(target.major).\(target.minor))"
                )
            }
            return Resolved(udid: existing.cloneUDID, name: existing.name,
                            createdNow: false,
                            runtime: existing.runtimeIdentifier.flatMap {
                                SimRuntimeVersion.parse(runtimeIdentifier: $0)
                            })
        }

        guard let requested = requestedDevice, !requested.isEmpty else {
            return nil
        }

        let template = try pickNewestTemplate(name: requested,
                                                requestedRuntime: requestedRuntime)
        let cloneName = cloneDisplayName(originalName: template.name, task: task)
        let newUDID = try simctl.clone(sourceUDID: template.udid, newName: cloneName)

        let record = TaskState.SimulatorRecord(
            cloneUDID: newUDID,
            sourceUDID: template.udid,
            name: cloneName,
            templateName: template.name,
            runtimeIdentifier: template.runtime
        )
        state.simulator = record
        try fs.writeFileAtomic(state.jsonData(), to: statePath)

        return Resolved(udid: record.cloneUDID, name: record.name,
                        createdNow: true,
                        runtime: template.runtimeVersion)
    }

    /// `xcrun simctl bootstatus -b` — boots the device if shutdown,
    /// then waits for boot completion. Idempotent.
    public func bootIfNeeded(udid: String) throws {
        try simctl.bootstatusBoot(udid: udid)
    }

    /// `xcrun simctl shutdown <udid>`. Idempotent at the simctl layer
    /// (no-ops on an already-shutdown device).
    public func shutdown(udid: String) throws {
        try simctl.shutdown(udid: udid)
    }

    /// Shutdown-then-erase the bound clone for `task`. `simctl erase`
    /// rejects booted devices, so this is the safe ordering.
    public func eraseClone(udid: String) throws {
        try simctl.shutdown(udid: udid)
        try simctl.erase(udid: udid)
    }

    /// Read `state.simulator` for `task`, returning nil when there's
    /// no binding. Throws when state.json is missing/corrupt.
    public func lookupBound(task: TaskName) throws -> TaskState.SimulatorRecord? {
        let statePath = workspace.statePath(for: task)
        guard fs.fileExists(at: statePath) else {
            throw VibeChardError.stateFileCorrupt(
                path: statePath,
                underlying: "missing — run `vch repair`"
            )
        }
        let data = try fs.readFile(at: statePath)
        let state = try TaskState.parse(data)
        return state.simulator
    }

    /// Look up live state for a UDID via `simctl list devices --json`
    /// (the unfiltered variant). Returns nil when the device is gone
    /// from simctl entirely (e.g. someone deleted it out-of-band) —
    /// `vch doctor` flags this as a stale binding.
    public func info(udid: String) throws -> SimDevice? {
        let all = try simctl.allDevices()
        return all.first(where: { $0.udid == udid })
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
    ///
    /// `requestedRuntime` (#11) further filters by the runtime
    /// identifier. Accepted forms:
    ///   • raw identifier:  `com.apple.CoreSimulator.SimRuntime.iOS-26-4`
    ///   • dashed iOS form: `iOS-26-4`
    ///   • dotted iOS form: `iOS 26.4`
    /// All three normalize to the same SimRuntimeVersion.
    func pickNewestTemplate(
        name: String,
        requestedRuntime: String? = nil
    ) throws -> SimDevice {
        let all = try simctl.availableDevices()
        var matches = all.filter { $0.isAvailable && $0.name == name }
        if let req = requestedRuntime,
           let target = parseRuntimeRequest(req) {
            matches = matches.filter { $0.runtimeVersion == target }
            guard !matches.isEmpty else {
                // Surface the runtimes we DO have for this device so
                // the user can copy-paste the right `--runtime` value.
                let available = all
                    .filter { $0.isAvailable && $0.name == name }
                    .compactMap { $0.runtimeVersion.map { "iOS \($0.major).\($0.minor)" } }
                throw VibeChardError.simulatorTemplateNotFound(
                    name: "\(name) (runtime '\(req)' — available: \(available.isEmpty ? "none" : available.joined(separator: ", ")))"
                )
            }
        }
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

    /// Normalize the user's `--runtime` argument into a comparable
    /// `SimRuntimeVersion`. Accepts the three forms documented on
    /// `pickNewestTemplate`. Returns nil for unrecognized strings
    /// rather than throwing so the caller can decide whether to
    /// surface that as an error or fall through to the unfiltered
    /// path.
    func parseRuntimeRequest(_ raw: String) -> SimRuntimeVersion? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = SimRuntimeVersion.parse(runtimeIdentifier: trimmed) {
            return parsed
        }
        // `iOS-26-4` → fabricate a fake suffix so the existing parser handles it.
        if trimmed.hasPrefix("iOS-") {
            return SimRuntimeVersion.parse(
                runtimeIdentifier: "x.\(trimmed)"
            )
        }
        // `iOS 26.4` / `iOS 26`.
        if trimmed.lowercased().hasPrefix("ios ") {
            let body = trimmed.dropFirst("ios ".count)
            let parts = body.split(whereSeparator: { $0 == "." || $0 == "-" })
            guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
            let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return SimRuntimeVersion(major: major, minor: minor)
        }
        return nil
    }

    /// `<original>-vch-<task>` — plain ASCII suffix, friendlier for
    /// shells, JSON, and Apple's Simulator picker. Pre-v0.3.0 used
    /// `<original> · vch[<task>]`; existing clones keep working via
    /// dual-prefix scanning in `DoctorService`. Capped at 255 chars
    /// (HFS+/APFS limit) defensively.
    func cloneDisplayName(originalName: String, task: TaskName) -> String {
        let raw = "\(originalName)-vch-\(task.raw)"
        if raw.count <= 255 { return raw }
        return String(raw.prefix(255))
    }

    /// Best-effort strip of either clone-name suffix from a persisted
    /// `state.simulator.name`. Used only when `templateName` is absent
    /// (legacy state written by vch ≤ v0.1.x). Falls through to the
    /// untouched name when neither suffix matches.
    static func stripCloneSuffix(from name: String, task: TaskName) -> String {
        let modern = "-vch-\(task.raw)"
        if name.hasSuffix(modern) {
            return String(name.dropLast(modern.count))
        }
        let legacy = " · vch[\(task.raw)]"
        if name.hasSuffix(legacy) {
            return String(name.dropLast(legacy.count))
        }
        return name
    }
}
