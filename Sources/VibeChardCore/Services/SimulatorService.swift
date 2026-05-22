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
        /// Parsed simulator version of the clone's runtime, surfaced into
        /// the `vch build` / `vch test` log so the user can spot
        /// silent runtime drift (#11). nil for legacy state
        /// (vch ≤ v0.1.x) or unknown future runtimes.
        public let runtime: SimRuntimeVersion?

        public var platform: SimRuntimeVersion.Platform? {
            runtime?.platform
        }

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
    /// Multi-binding semantics (#99): a task may bind to several
    /// platform clones (e.g. an iOS clone for the host app + a
    /// watchOS clone for the companion). The resolution rules are:
    ///
    ///   * No `--device`:
    ///     with `requestedPlatform`, reuse only bindings from that
    ///     platform; without it, 0 bindings → return nil, 1 binding →
    ///     reuse it, ≥2 bindings → throw `simulatorBindingAmbiguous`.
    ///
    ///   * With `--device` (and optionally `--runtime`):
    ///     filter existing bindings by `templateName` (and runtime
    ///     when given). If exactly one matches, reuse it. If none
    ///     match, clone a new one and APPEND it to `state.simulators`.
    ///     If two or more match (e.g. same device on two runtimes
    ///     and user didn't pin `--runtime`), throw
    ///     `simulatorBindingAmbiguous`.
    ///
    /// Pre-#99 callers that always passed `--device` and bound a
    /// single platform keep their idempotent reuse behaviour
    /// unchanged.
    public func ensureClone(
        task: TaskName,
        requestedDevice: String?,
        requestedRuntime: String? = nil,
        requestedPlatform: SimRuntimeVersion.Platform? = nil,
        shutdownTemplate: Bool = false
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

        let existing = try pruneStaleSimulatorBindings(
            statePath: statePath,
            state: &state
        )

        // No --device: pure-reuse path. 0 → nil, 1 → reuse, ≥2 → ambiguous.
        // When the caller knows the scheme's simulator platform, scope
        // reuse to that platform so a watchOS binding cannot leak into
        // an iOS build just because it is the only recorded clone.
        guard let requested = requestedDevice, !requested.isEmpty else {
            if let requestedPlatform {
                let matches = try existing.filter { rec in
                    try platform(for: rec) == requestedPlatform
                }
                switch matches.count {
                case 0:
                    if existing.isEmpty { return nil }
                    throw VibeChardError.simulatorBindingPlatformUnavailable(
                        taskName: task.raw,
                        platform: requestedPlatform.xcodebuildDestinationPlatform,
                        candidates: existing.map(\.name)
                    )
                case 1:
                    let only = matches[0]
                    try assertRuntimeMatches(existing: only, requestedRuntime: requestedRuntime, task: task)
                    return try resolved(from: only, createdNow: false)
                default:
                    throw VibeChardError.simulatorBindingAmbiguous(
                        taskName: task.raw,
                        candidates: matches.map(\.name)
                    )
                }
            }
            switch existing.count {
            case 0:
                return nil
            case 1:
                let only = existing[0]
                // Honour the legacy runtime-mismatch guard for the
                // single-binding case: when the user pinned
                // `--runtime` but recorded runtime disagrees, refuse.
                try assertRuntimeMatches(existing: only, requestedRuntime: requestedRuntime, task: task)
                return try resolved(from: only, createdNow: false)
            default:
                throw VibeChardError.simulatorBindingAmbiguous(
                    taskName: task.raw,
                    candidates: existing.map(\.name)
                )
            }
        }

        // --device specified: filter and route.
        let matches = existing.filter { rec in
            matchesBinding(rec, device: requested, runtime: requestedRuntime, task: task)
        }
        switch matches.count {
        case 1:
            return try resolved(from: matches[0], createdNow: false)
        case 2...:
            throw VibeChardError.simulatorBindingAmbiguous(
                taskName: task.raw,
                candidates: matches.map(\.name)
            )
        default:
            break  // 0 matches → clone a new binding below
        }

        // #47: warm-template lookup wins over the Apple-template scan
        // when the user pinned a runtime AND a vch-managed warm
        // template exists for `<requested>:<runtime>`. The clone path
        // is otherwise identical, so the rest of state.json (including
        // `templateName` + `runtimeIdentifier`) keeps the *device*
        // identity instead of the warm template's `vch-warm[...]` name
        // — that way later reuse comparisons still match the user's
        // `--device "iPhone 16"` argument as expected.
        let template: SimDevice
        let sourceKind: TaskState.SourceKind
        if let warm = try pickWarmTemplate(deviceName: requested,
                                           requestedRuntime: requestedRuntime) {
            template = warm
            sourceKind = .warmTemplate
        } else {
            template = try pickNewestTemplate(name: requested,
                                              requestedRuntime: requestedRuntime,
                                              requestedPlatform: requestedPlatform)
            sourceKind = .appleTemplate
        }
        let cloneName = cloneDisplayName(originalName: requested, task: task)
        let newUDID = try cloneTemplate(
            template: template,
            cloneName: cloneName,
            shutdownTemplate: shutdownTemplate
        )

        let record = TaskState.SimulatorRecord(
            cloneUDID: newUDID,
            sourceUDID: template.udid,
            name: cloneName,
            templateName: requested,
            runtimeIdentifier: template.runtime,
            sourceKind: sourceKind
        )
        state.setSimulators(existing + [record])
        try fs.writeFileAtomic(state.jsonData(), to: statePath)

        return Resolved(udid: record.cloneUDID, name: record.name,
                        createdNow: true,
                        runtime: template.runtimeVersion)
    }

    /// Build a `Resolved` from an existing binding. Centralised so
    /// the parsing of `runtimeIdentifier → SimRuntimeVersion` stays
    /// in one place.
    private func resolved(from rec: TaskState.SimulatorRecord, createdNow: Bool) throws -> Resolved {
        Resolved(
            udid: rec.cloneUDID,
            name: rec.name,
            createdNow: createdNow,
            runtime: try runtime(for: rec)
        )
    }

    private func runtime(for rec: TaskState.SimulatorRecord) throws -> SimRuntimeVersion? {
        if let runtime = rec.runtimeVersion {
            return runtime
        }
        return try info(udid: rec.cloneUDID)?.runtimeVersion
    }

    private func platform(for rec: TaskState.SimulatorRecord) throws -> SimRuntimeVersion.Platform? {
        try runtime(for: rec)?.platform
    }

    /// Predicate used by the `--device` filter. Compares against the
    /// persisted `templateName`, falling back to a suffix-strip on
    /// `name` for state.json written by vch ≤ v0.1.x. When `runtime`
    /// is supplied, also requires the binding's recorded runtime to
    /// match — bindings with a missing `runtimeIdentifier` (legacy)
    /// are excluded from runtime-filtered queries so the user can
    /// safely add a new runtime-pinned clone without colliding with
    /// the legacy record. An empty `device` skips the device check
    /// (used by the CLI selector when only `--runtime` was given).
    private func matchesBinding(
        _ rec: TaskState.SimulatorRecord,
        device: String,
        runtime: String?,
        task: TaskName
    ) -> Bool {
        if !device.isEmpty {
            let stored = rec.templateName ?? Self.stripCloneSuffix(from: rec.name, task: task)
            guard stored == device else { return false }
        }
        guard let raw = runtime, let target = parseRuntimeRequest(raw) else {
            return true
        }
        guard let id = rec.runtimeIdentifier,
              let bound = SimRuntimeVersion.parse(runtimeIdentifier: id) else {
            return false
        }
        return bound == target
    }

    /// Preserves the pre-#99 single-binding contract for the
    /// "no --device, reuse the one binding I already have" path:
    /// if the user pinned `--runtime` and the recorded runtime
    /// disagrees, throw `simulatorAlreadyBound` so the user sees
    /// the same actionable message they did before. Legacy records
    /// with no `runtimeIdentifier` keep silently reusing for
    /// backwards compatibility.
    private func assertRuntimeMatches(
        existing: TaskState.SimulatorRecord,
        requestedRuntime: String?,
        task: TaskName
    ) throws {
        guard let raw = requestedRuntime,
              let target = parseRuntimeRequest(raw),
              let id = existing.runtimeIdentifier,
              let bound = SimRuntimeVersion.parse(runtimeIdentifier: id),
              bound != target else {
            return
        }
        let device = existing.templateName ?? Self.stripCloneSuffix(from: existing.name, task: task)
        throw VibeChardError.simulatorAlreadyBound(
            taskName: task.raw,
            currentName: "\(existing.name) (runtime \(bound.dottedLabel))",
            requestedName: "\(device) (runtime \(target.dottedLabel))"
        )
    }

    /// Wrap `simctl.clone` with optional auto-shutdown of the source
    /// template when it's currently `Booted`.
    ///
    /// Background: `simctl clone` refuses to clone a booted device with
    /// `Unable to clone device in current state: Booted`. The template
    /// gets booted any time the user opens the simulator UI (warm
    /// templates by design encourage you to launch your app there)
    /// and forgets to shut it down afterwards. The first `vch build`
    /// in a new task then explodes with a stderr blob and the user
    /// has to copy-paste a UDID into a `simctl shutdown` command.
    ///
    /// vch refuses to shut the template down by default: per hard
    /// rule #9, the user owns the lifecycle of any *shared* resource,
    /// and a warm template is shared across tasks. The opt-in flag
    /// `--shutdown-template` lets the caller delegate that policy
    /// decision once per invocation. (#66)
    private func cloneTemplate(
        template: SimDevice,
        cloneName: String,
        shutdownTemplate: Bool
    ) throws -> String {
        do {
            return try simctl.clone(sourceUDID: template.udid, newName: cloneName)
        } catch let VibeChardError.externalCommandFailed(_, _, stderr)
        where SimctlCloneErrors.isTemplateBooted(stderr: stderr) {
            guard shutdownTemplate else {
                throw VibeChardError.simulatorTemplateBooted(
                    name: template.name,
                    udid: template.udid
                )
            }
            try simctl.shutdown(udid: template.udid)
            return try simctl.clone(sourceUDID: template.udid, newName: cloneName)
        }
    }

    /// `xcrun simctl bootstatus -b` — boots the device if shutdown,
    /// then waits for boot completion. Idempotent. A follow-up state
    /// check catches unhealthy CoreSimulator cases where bootstatus
    /// returns but the destination remains Shutdown / unusable.
    public func bootIfNeeded(udid: String, name: String? = nil) throws {
        try simctl.bootstatusBoot(udid: udid)
        try verifyBooted(udid: udid, name: name ?? udid)
    }

    private func verifyBooted(udid: String, name: String) throws {
        let devices = try simctl.allDevices()
        guard let device = devices.first(where: { $0.udid == udid }) else {
            throw VibeChardError.simulatorBootVerificationFailed(
                name: name,
                udid: udid,
                state: "missing from simctl list"
            )
        }
        guard let state = device.state else { return }
        guard state == "Booted" else {
            throw VibeChardError.simulatorBootVerificationFailed(
                name: name,
                udid: udid,
                state: state
            )
        }
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

    /// Read the task's single simulator binding (#99). Returns nil
    /// when there's no binding. Throws `simulatorBindingAmbiguous`
    /// when the task has two or more bindings — callers that want
    /// the full set use `lookupAllBindings`, and callers that take
    /// a `--device` selector should resolve through
    /// `resolveBindingForCLI`.
    public func lookupBound(task: TaskName) throws -> TaskState.SimulatorRecord? {
        let bindings = try lookupAllBindings(task: task)
        switch bindings.count {
        case 0:
            return nil
        case 1:
            return bindings[0]
        default:
            throw VibeChardError.simulatorBindingAmbiguous(
                taskName: task.raw,
                candidates: bindings.map(\.name)
            )
        }
    }

    /// Read every live simulator binding persisted for `task` (#99).
    /// Bindings whose clone UDID has disappeared from `simctl list`
    /// are pruned from state before returning (#111).
    /// Always returns a (possibly empty) list — never throws on
    /// ambiguity. Throws when `state.json` is missing/corrupt, or
    /// when simctl cannot be queried for a non-empty binding list.
    public func lookupAllBindings(task: TaskName) throws -> [TaskState.SimulatorRecord] {
        let statePath = workspace.statePath(for: task)
        guard fs.fileExists(at: statePath) else {
            throw VibeChardError.stateFileCorrupt(
                path: statePath,
                underlying: "missing — run `vch repair`"
            )
        }
        let data = try fs.readFile(at: statePath)
        var state = try TaskState.parse(data)
        return try pruneStaleSimulatorBindings(
            statePath: statePath,
            state: &state
        )
    }

    private func pruneStaleSimulatorBindings(
        statePath: String,
        state: inout TaskState
    ) throws -> [TaskState.SimulatorRecord] {
        let existing = state.allSimulators
        guard !existing.isEmpty else { return [] }

        let liveUDIDs = Set(try simctl.allDevices().map(\.udid))
        let live = existing.filter { liveUDIDs.contains($0.cloneUDID) }
        guard live.count != existing.count else { return existing }

        state.setSimulators(live)
        try fs.writeFileAtomic(state.jsonData(), to: statePath)
        return live
    }

    /// Resolve which binding a CLI subcommand should operate on (#99).
    /// Used by `vch sim erase / shutdown / info` and any future
    /// per-binding command that needs to disambiguate when the task
    /// has more than one clone.
    ///
    /// Returns nil when the task has no bindings at all (caller emits
    /// "no clone bound"); otherwise:
    ///   * neither `device` nor `runtime` given:
    ///     1 binding → return it; ≥2 → `simulatorBindingAmbiguous`.
    ///   * `device` (and optionally `runtime`) given: filter
    ///     `lookupAllBindings`. 1 match → return it; 0 → throw
    ///     `taskNotFound`-style `simulatorTemplateNotFound`; ≥2 →
    ///     `simulatorBindingAmbiguous` over the remaining matches.
    public func resolveBindingForCLI(
        task: TaskName,
        device: String?,
        runtime: String? = nil
    ) throws -> TaskState.SimulatorRecord? {
        let all = try lookupAllBindings(task: task)
        if all.isEmpty { return nil }

        if (device == nil || device!.isEmpty) && (runtime == nil || runtime!.isEmpty) {
            switch all.count {
            case 1: return all[0]
            default:
                throw VibeChardError.simulatorBindingAmbiguous(
                    taskName: task.raw,
                    candidates: all.map(\.name)
                )
            }
        }

        let matches = all.filter { rec in
            matchesBinding(rec, device: device ?? "", runtime: runtime, task: task)
        }
        switch matches.count {
        case 0:
            // Surface the actual binding names so the user can copy-paste
            // a `--device` value that exists.
            let detail: String
            if let runtime, !runtime.isEmpty {
                detail = "\(device ?? "(any)") (runtime \(runtime))"
            } else {
                detail = device ?? "(any)"
            }
            throw VibeChardError.simulatorTemplateNotFound(
                name: "\(detail) — bindings: \(all.map(\.name).joined(separator: ", "))"
            )
        case 1:
            return matches[0]
        default:
            throw VibeChardError.simulatorBindingAmbiguous(
                taskName: task.raw,
                candidates: matches.map(\.name)
            )
        }
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
    /// "Newest" = highest runtime version (then arbitrary stable
    /// tiebreak by UDID). Templates with `isAvailable == false` are
    /// filtered out.
    ///
    /// Lazy creation (#110): if the device type is valid but no base device
    /// exists, vch auto-creates it via `simctl create`. The user still owns
    /// the lifecycle (can delete via `vch doctor --clean`), but doesn't need
    /// to manually run `xcrun simctl create` first.
    ///
    /// `requestedRuntime` (#11) further filters by the runtime
    /// identifier. Accepted forms (per platform — iOS / watchOS /
    /// tvOS / visionOS):
    ///   • raw identifier:  `com.apple.CoreSimulator.SimRuntime.iOS-26-4`
    ///   • dashed form:     `iOS-26-4` / `watchOS-11-5` / `xrOS-2-5`
    ///   • dotted form:     `iOS 26.4` / `watchOS 11.5` / `visionOS 2.5`
    /// All forms normalize to the same SimRuntimeVersion. The
    /// CoreSimulator slug for visionOS is `xrOS`; the parser also
    /// accepts the user-friendly `visionOS` prefix as an alias.
    func pickNewestTemplate(
        name: String,
        requestedRuntime: String? = nil,
        requestedPlatform: SimRuntimeVersion.Platform? = nil
    ) throws -> SimDevice {
        let all = try simctl.availableDevices()
        var matches = all.filter { $0.isAvailable && $0.name == name }

        // If requestedRuntime is specified, filter further. But if no matches
        // are found after filtering, DON'T throw yet — we may auto-create.
        if let req = requestedRuntime,
           let target = parseRuntimeRequest(req) {
            let runtimeFiltered = matches.filter { $0.runtimeVersion == target }
            if !runtimeFiltered.isEmpty {
                matches = runtimeFiltered
            } else if !matches.isEmpty {
                // We have devices with this name but NOT this runtime.
                // Surface the runtimes we DO have so the user can copy-paste.
                let available = all
                    .filter { $0.isAvailable && $0.name == name }
                    .compactMap { $0.runtimeVersion?.dottedLabel }
                throw VibeChardError.simulatorTemplateNotFound(
                    name: "\(name) (runtime '\(req)' — available: \(available.isEmpty ? "none" : available.joined(separator: ", ")))"
                )
            }
            // else: no devices with this name at all, matches stays empty,
            // and we'll try auto-create below.
        }

        guard !matches.isEmpty else {
            // No available device found. Try lazy creation (#110):
            // Attempt to auto-create the base device.
            return try createBaseDeviceIfNeeded(
                name: name,
                requestedRuntime: requestedRuntime,
                requestedPlatform: requestedPlatform
            )
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
        // Safe by construction: the guard above rejects empty `matches`,
        // so `sorted` carries the same count and `first` is non-nil.
        guard let pick = sorted.first else {
            throw VibeChardError.simulatorTemplateNotFound(name: name)
        }
        return pick
    }

    /// Attempt to auto-create a base device when the device type is valid
    /// but no instance exists yet (#110). Throws with diagnostic if
    /// device type is not installed or runtime is invalid.
    private func createBaseDeviceIfNeeded(
        name: String,
        requestedRuntime: String?,
        requestedPlatform: SimRuntimeVersion.Platform?
    ) throws -> SimDevice {
        // Determine the target runtime. Must be specified.
        guard let req = requestedRuntime else {
            throw VibeChardError.simulatorTemplateNotFound(
                name: "\(name) — no base device exists and --runtime not specified. \(missingRuntimeHint(deviceName: name, requestedPlatform: requestedPlatform))"
            )
        }

        guard let targetRuntime = parseRuntimeRequest(req) else {
            throw VibeChardError.simulatorTemplateNotFound(
                name: "\(name) (runtime '\(req)') — unrecognized runtime format"
            )
        }

        // Attempt to create the device with the target runtime.
        let newUDID: String
        do {
            newUDID = try simctl.create(
                name: name,
                deviceTypeID: name,
                runtimeID: targetRuntime.runtimeIdentifier
            )
        } catch let VibeChardError.externalCommandFailed(cmd, _, stderr) {
            // Diagnose the failure to help the user.
            let lower = stderr.lowercased()
            if lower.contains("invalid device type") {
                throw VibeChardError.simulatorTemplateNotFound(
                    name: "Device type '\(name)' not installed. Check: xcrun simctl list devicetypes"
                )
            } else if lower.contains("no such runtime") || lower.contains("runtime.*not found") {
                throw VibeChardError.simulatorTemplateNotFound(
                    name: "Runtime '\(targetRuntime.dottedLabel)' not installed. Check: xcrun simctl list runtimes"
                )
            }
            throw VibeChardError.externalCommandFailed(cmd: cmd, exitCode: -1, stderr: stderr)
        } catch {
            throw error
        }

        // Successfully created. Return the new device.
        return SimDevice(
            udid: newUDID,
            name: name,
            runtime: targetRuntime.runtimeIdentifier,
            runtimeVersion: targetRuntime,
            isAvailable: true,
            state: "Shutdown"
        )
    }

    private func missingRuntimeHint(
        deviceName: String,
        requestedPlatform: SimRuntimeVersion.Platform?
    ) -> String {
        let platform = requestedPlatform ?? Self.inferPlatform(deviceName: deviceName)
        if let platform {
            if let runtime = newestAvailableRuntime(for: platform) {
                return "Try: --runtime '\(runtime.dottedLabel)'"
            }
            return "Pass a \(platform.rawValue) runtime from `xcrun simctl list runtimes`, "
                + "for example: --runtime '\(platform.rawValue) <version>'"
        }
        return "Pass --runtime <version> using a label from `xcrun simctl list runtimes`, "
            + "or the full SimRuntime identifier"
    }

    private func newestAvailableRuntime(
        for platform: SimRuntimeVersion.Platform
    ) -> SimRuntimeVersion? {
        (try? simctl.availableRuntimes())?
            .filter { $0.platform == platform }
            .max()
    }

    private static func inferPlatform(
        deviceName: String
    ) -> SimRuntimeVersion.Platform? {
        let lower = deviceName.lowercased()
        if lower.contains("watch") { return .watchOS }
        if lower.contains("apple tv") || lower.contains("tv") { return .tvOS }
        if lower.contains("vision") { return .visionOS }
        if lower.contains("iphone") || lower.contains("ipad") || lower.contains("ipod") {
            return .iOS
        }
        return nil
    }

    /// Normalize the user's `--runtime` argument into a comparable
    /// `SimRuntimeVersion`. Accepts the three forms documented on
    /// `pickNewestTemplate` for any of the four supported platforms
    /// (iOS / watchOS / tvOS / visionOS). Returns `nil` for
    /// unrecognized strings rather than throwing so the caller can
    /// decide whether to surface that as an error or fall through to
    /// the unfiltered path.
    func parseRuntimeRequest(_ raw: String) -> SimRuntimeVersion? {
        SimRuntimeVersion.parse(runtimeLabel: raw)
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
