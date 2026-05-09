import Foundation

/// Warm-template feature surface on `SimulatorService` (#47).
///
/// **What & why.** A "warm template" is a simulator device that vch
/// keeps in shutdown state with first-boot caches already primed
/// (created → booted via `simctl bootstatus -b` → shutdown). Per-task
/// `simctl clone` operations then inherit those primed caches, so the
/// cloned device boots in seconds instead of tens of seconds.
///
/// **Empirical justification.** Cold path (`simctl create` from an
/// Apple template + first boot, iPhone 16 + iOS 26.4, N=5 median)
/// measured **30.75 s**. Warm path (`simctl clone` from a primed
/// template + boot, same conditions) measured **9.41 s**. Savings:
/// 21.35 s absolute (69.4 %). See PR #47 for the SPIKE methodology.
///
/// **Lifecycle.** Warm templates are user-managed only — they are
/// created by `vch sim warm-template create` and destroyed by
/// `vch sim warm-template remove`. `vch doctor` lists them but never
/// auto-cleans them (lifecycle is decoupled from any task's lifecycle
/// — see AGENTS.md hard rule #9). `vch remove` of an individual task
/// touches per-task clones only, never warm templates.
///
/// **Persistence.** Zero on-disk metadata. The simctl device name
/// pattern `vch-warm[<deviceName>:<runtimeLabel>]` is the only source
/// of truth (matches AGENTS.md rule #7 — no config files, no
/// `~/.vch*`). Tests confirmed `simctl create` preserves the bracketed
/// name byte-for-byte.
extension SimulatorService {

    // MARK: - public API

    /// Create a new warm template for `deviceName` + `runtimeLabel`.
    ///
    /// Steps:
    /// 1. Parse `runtimeLabel` (accepts `"iOS 26.4"` / `"iOS-26-4"` /
    ///    raw `com.apple.CoreSimulator.SimRuntime.iOS-26-4`).
    /// 2. Compose canonical name `vch-warm[<deviceName>:iOS X.Y]`.
    ///    Refuse to create if a device by that name already exists
    ///    (caller should `remove` first to recreate).
    /// 3. `simctl create` with the canonical CoreSimulator runtime ID
    ///    derived from the parsed version.
    /// 4. `simctl bootstatus -b` to prime first-boot caches.
    /// 5. `simctl shutdown` to leave the template in static state.
    ///
    /// On any failure mid-flight, the partially-created device is
    /// best-effort-deleted before rethrowing so the user doesn't end
    /// up with a half-primed orphan masquerading as a real warm
    /// template.
    @discardableResult
    public func createWarmTemplate(
        deviceName: String,
        runtimeLabel: String
    ) throws -> WarmTemplateRecord {
        guard !deviceName.isEmpty else {
            throw VibeChardError.missingArgument("device name")
        }
        guard let parsedVersion = parseRuntimeRequest(runtimeLabel) else {
            throw VibeChardError.invalidRuntime(runtimeLabel)
        }
        let canonicalLabel = parsedVersion.dottedLabel
        let runtimeID = parsedVersion.iOSRuntimeIdentifier
        let templateName = WarmTemplateName.format(
            deviceName: deviceName, runtimeLabel: canonicalLabel
        )

        // Refuse to clobber. If a same-named device is already present
        // (regardless of state), the user has to `remove` first. This
        // is conservative on purpose — recreate-with-implicit-replace
        // is a footgun (would silently destroy a busy warm template).
        let existing = try simctl.allDevices().first { $0.name == templateName }
        if let existing {
            throw VibeChardError.warmTemplateAlreadyExists(
                name: templateName,
                udid: existing.udid
            )
        }

        let newUDID = try simctl.create(
            name: templateName,
            deviceTypeID: deviceName,
            runtimeID: runtimeID
        )

        // From here on, on any thrown error we best-effort-delete the
        // device we just created so we don't leave a stuck "Creating"
        // or "Booted" device claiming to be a warm template.
        do {
            try simctl.bootstatusBoot(udid: newUDID)
            try simctl.shutdown(udid: newUDID)
        } catch {
            try? simctl.shutdown(udid: newUDID)
            try? simctl.delete(udid: newUDID)
            throw error
        }

        return WarmTemplateRecord(
            name: templateName,
            deviceName: deviceName,
            runtimeLabel: canonicalLabel,
            udid: newUDID,
            state: "Shutdown",
            health: .ok
        )
    }

    /// List every vch-managed warm template currently known to simctl.
    /// Returns rows sorted by `(deviceName, runtimeLabel)` for stable
    /// output (`vch sim warm-template list` and `vch doctor` both
    /// surface this list verbatim).
    public func listWarmTemplates() throws -> [WarmTemplateRecord] {
        let all = try simctl.allDevices()
        var rows: [WarmTemplateRecord] = []
        for d in all {
            guard WarmTemplateName.isWarmTemplateName(d.name) else { continue }
            guard let parsed = WarmTemplateName.parse(d.name) else {
                rows.append(WarmTemplateRecord(
                    name: d.name,
                    deviceName: "",
                    runtimeLabel: "",
                    udid: d.udid,
                    state: d.state,
                    health: .malformed
                ))
                continue
            }
            let health: WarmTemplateRecord.Health
            if d.isAvailable == false {
                health = .stale
            } else if let s = d.state, s.lowercased() != "shutdown" {
                health = .booted
            } else {
                health = .ok
            }
            rows.append(WarmTemplateRecord(
                name: d.name,
                deviceName: parsed.deviceName,
                runtimeLabel: parsed.runtimeLabel,
                udid: d.udid,
                state: d.state,
                health: health
            ))
        }
        rows.sort {
            if $0.deviceName != $1.deviceName { return $0.deviceName < $1.deviceName }
            return $0.runtimeLabel < $1.runtimeLabel
        }
        return rows
    }

    /// Shutdown-then-delete the warm template for `deviceName` +
    /// `runtimeLabel`. `runtimeLabel` is normalized through the same
    /// parser as `--runtime` everywhere else so `iOS 26.4`,
    /// `iOS-26-4`, and the verbose CoreSimulator ID all resolve to
    /// the same template. Throws `simulatorTemplateNotFound` when no
    /// matching template exists.
    public func removeWarmTemplate(
        deviceName: String,
        runtimeLabel: String
    ) throws {
        guard let parsedVersion = parseRuntimeRequest(runtimeLabel) else {
            throw VibeChardError.invalidRuntime(runtimeLabel)
        }
        let canonicalLabel = parsedVersion.dottedLabel
        let templateName = WarmTemplateName.format(
            deviceName: deviceName, runtimeLabel: canonicalLabel
        )
        let all = try simctl.allDevices()
        guard let target = all.first(where: { $0.name == templateName }) else {
            throw VibeChardError.simulatorTemplateNotFound(name: templateName)
        }
        try simctl.shutdown(udid: target.udid)
        try simctl.delete(udid: target.udid)
    }

    // MARK: - reuse-path integration

    /// Look up a warm-template UDID matching `deviceName` +
    /// `requestedRuntime`. Used by `ensureClone` as priority #2 in
    /// the lookup tree (after existing-clone reuse, before the
    /// Apple-template scan). Returns `nil` when no warm template
    /// matches — the caller falls through to `pickNewestTemplate`.
    ///
    /// Unhealthy warm templates (stale runtime, currently booted,
    /// malformed name) are deliberately skipped here so the build/
    /// test path doesn't silently clone off a degraded source. The
    /// user sees them via `vch sim warm-template list` / `vch doctor`
    /// and decides whether to remove + recreate.
    func pickWarmTemplate(
        deviceName: String,
        requestedRuntime: String?
    ) throws -> SimDevice? {
        // Without an explicit runtime we cannot identify a single
        // warm template (different runtimes for the same device =
        // different templates). Falling through to the Apple-template
        // path's "newest runtime wins" semantics is the only sane
        // default; warm-template lookup requires an explicit pin.
        guard let runtimeReq = requestedRuntime,
              let parsed = parseRuntimeRequest(runtimeReq) else {
            return nil
        }
        let canonicalLabel = parsed.dottedLabel
        let templateName = WarmTemplateName.format(
            deviceName: deviceName, runtimeLabel: canonicalLabel
        )
        let all = try simctl.allDevices()
        guard let dev = all.first(where: { $0.name == templateName }) else {
            return nil
        }
        // Only honor healthy warm templates as clone sources.
        guard dev.isAvailable else { return nil }
        if let s = dev.state, s.lowercased() != "shutdown" { return nil }
        return dev
    }
}
