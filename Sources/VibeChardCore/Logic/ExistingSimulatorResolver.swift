import Foundation

/// Resolves the `--existing-sim <udid|name>` selector against a live
/// `xcrun simctl list devices` snapshot. (#162)
///
/// `--existing-sim` is the explicit opt-in for "install / build onto a
/// long-lived shared simulator I keep open and watch", as opposed to
/// vch's default per-task `simctl clone`. Two properties make this
/// distinct from `SimulatorService.ensureClone` and are the reason this
/// resolver never reads or writes `state.json`:
///
///   * No clone — the target already exists; vch only needs its UDID
///     and platform.
///   * No per-task binding — the simulator is a *shared* resource the
///     user owns (hard rule #9). Recording it in `state.simulators`
///     would make `vch land` / `vch rm` reap it, which is exactly the
///     opposite of what the user asked for.
///
/// Keeping selector resolution and the option-conflict rules here (in
/// Core) rather than in the `vch` CLI shell is deliberate: the CLI
/// target cannot be `@testable import`-ed, so any decision logic that
/// lives there is logic that cannot be unit-tested (AGENTS.md
/// engineering discipline #7).
public enum ExistingSimulatorResolver {
    /// A resolved shared simulator: the bits the build/run pipeline
    /// needs after selector resolution succeeds.
    public struct Match: Equatable, Sendable {
        public let udid: String
        public let name: String
        /// Parsed runtime of the device, used to derive the simulator
        /// platform for the xcodebuild `-destination`. `nil` when the
        /// device's runtime identifier is unparseable (an unknown
        /// future Apple platform), in which case the caller refuses
        /// with `simulatorPlatformUnknown` rather than guessing iOS.
        public let runtime: SimRuntimeVersion?

        public init(udid: String, name: String, runtime: SimRuntimeVersion?) {
            self.udid = udid
            self.name = name
            self.runtime = runtime
        }
    }

    /// Resolve `selector` (a UDID or a device name) against `devices`
    /// — typically the full `simctl list devices` superset so a booted
    /// shared device is always visible.
    ///
    /// Resolution order:
    ///   1. exact UDID match (case-insensitive). UDIDs are unique, so a
    ///      hit here is always unambiguous and wins over any name.
    ///   2. exact name match. 0 → `existingSimulatorNotFound`,
    ///      1 → that device, ≥2 → `existingSimulatorAmbiguous` listing
    ///      each candidate's UDID + runtime so the user can re-run with
    ///      the precise UDID.
    public static func resolve(
        selector rawSelector: String,
        devices: [SimDevice]
    ) throws -> Match {
        let selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else {
            throw VibeChardError.missingArgument("--existing-sim")
        }

        // 1. UDID match wins (case-insensitive — simctl prints upper
        //    case, but users paste from all sorts of places).
        if let byUDID = devices.first(where: {
            $0.udid.caseInsensitiveCompare(selector) == .orderedSame
        }) {
            return Match(udid: byUDID.udid, name: byUDID.name,
                         runtime: byUDID.runtimeVersion)
        }

        // 2. Exact name match.
        let byName = devices.filter { $0.name == selector }
        switch byName.count {
        case 0:
            throw VibeChardError.existingSimulatorNotFound(selector: selector)
        case 1:
            let device = byName[0]
            return Match(udid: device.udid, name: device.name,
                         runtime: device.runtimeVersion)
        default:
            throw VibeChardError.existingSimulatorAmbiguous(
                selector: selector,
                candidates: candidateLabels(byName)
            )
        }
    }

    /// Validate that `--existing-sim` is not combined with options that
    /// only make sense for the per-task clone / template path. Pure so
    /// the CLI stays a thin shell over a unit-tested rule set.
    ///
    ///   * `--device` selects a *template* to clone — combining it with
    ///     an explicit existing device is two ways to pick the same
    ///     thing, so it's a hard conflict.
    ///   * `--no-sim` opts out of any simulator destination entirely;
    ///     `--existing-sim` is the opposite (build *for* a specific
    ///     simulator), so the two contradict.
    ///   * `--runtime` pins which template runtime to clone; the
    ///     existing device's runtime is already fixed.
    ///   * `--erase-clone` would wipe the shared simulator's state —
    ///     refused outright (hard rule #9: vch never mutates a resource
    ///     it does not own).
    ///   * `--shutdown-template` only applies when a clone is taken off
    ///     a Booted warm template; no clone happens here.
    public static func validateOptions(
        existingSim: String?,
        device: String?,
        runtime: String?,
        eraseClone: Bool,
        shutdownTemplate: Bool,
        noSim: Bool = false
    ) throws {
        guard existingSim != nil else { return }
        if let device, !device.isEmpty {
            throw VibeChardError.existingSimulatorConflictsWithDevice
        }
        if noSim {
            throw VibeChardError.existingSimulatorIncompatibleOption(option: "--no-sim")
        }
        if let runtime, !runtime.isEmpty {
            throw VibeChardError.existingSimulatorIncompatibleOption(option: "--runtime")
        }
        if eraseClone {
            throw VibeChardError.existingSimulatorIncompatibleOption(option: "--erase-clone")
        }
        if shutdownTemplate {
            throw VibeChardError.existingSimulatorIncompatibleOption(option: "--shutdown-template")
        }
    }

    /// Render the ambiguous-name candidates newest-runtime-first, each
    /// as `<udid> — <runtime>`, so the disambiguation hint is copy-paste
    /// ready. Devices with an unparseable runtime sort last and render
    /// `unknown runtime`.
    private static func candidateLabels(_ devices: [SimDevice]) -> [String] {
        devices.sorted { lhs, rhs in
            switch (lhs.runtimeVersion, rhs.runtimeVersion) {
            case let (l?, r?):
                if l != r { return r < l }      // newer runtime first
                return lhs.udid < rhs.udid       // stable tiebreak
            case (.some, .none):
                return true                      // known runtime before unknown
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.udid < rhs.udid
            }
        }.map { device in
            let runtime = device.runtimeVersion?.dottedLabel ?? "unknown runtime"
            return "\(device.udid) — \(runtime)"
        }
    }
}
