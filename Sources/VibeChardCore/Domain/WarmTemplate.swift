import Foundation

/// Domain type for `vch sim warm-template list` rows (#47).
///
/// A "warm template" is a simulator device that vch keeps in shutdown
/// state with all first-boot caches already primed (the device was
/// booted once via `simctl bootstatus -b`, then shut down). Subsequent
/// per-task `simctl clone` operations inherit those primed caches, so
/// the cloned device boots in seconds instead of tens of seconds.
///
/// The on-disk source of truth is **the simctl device name itself**,
/// not a sidecar file or the worktree's `state.json`. Names follow:
///
///     vch-warm[<deviceName>:<runtimeLabel>]
///
/// where `runtimeLabel` is the dotted iOS form `iOS 26.4` (matching
/// what `vch test --runtime` accepts on the CLI). This zero-persistence
/// design is intentional — no metadata on the user's `~/.vch*`, no
/// global config file (AGENTS.md rule #7), and `simctl` is a single
/// authoritative source.
///
/// `Encodable` lives on the domain type so all three JSON surfaces
/// (`vch sim warm-template list --json`, `vch doctor --json`'s
/// `warmTemplates[]`, and the bug-report tarball's
/// `warm-templates.json`) emit byte-identical schemas. Field names
/// in the JSON output match the human column headers (`device`,
/// `runtime`) rather than the storage names (`deviceName`,
/// `runtimeLabel`) so an offline reviewer can copy-paste between the
/// `list` text output and the JSON view.
public struct WarmTemplateRecord: Equatable, Encodable, Sendable {
    /// The full simctl device name as stored, e.g.
    /// `vch-warm[iPhone 16:iOS 26.4]`.
    public let name: String
    /// Device-template name parsed out of the bracketed payload.
    public let deviceName: String
    /// Runtime label parsed out of the bracketed payload, e.g.
    /// `iOS 26.4`. This is the same string format `vch test --runtime`
    /// accepts on the CLI, so users can copy/paste between commands.
    public let runtimeLabel: String
    /// Live UDID of the warm template device.
    public let udid: String
    /// Live state from `simctl list devices --json`. Expected to be
    /// `Shutdown` for a healthy warm template (Q4 of #47 design).
    public let state: String?
    /// Health classification surfaced in `vch sim warm-template list`
    /// and `vch doctor`. `ok` is the happy path; the other variants
    /// surface as visible warnings so the user can decide whether to
    /// `vch sim warm-template remove` and recreate.
    public let health: Health

    public enum Health: String, Equatable, Sendable, Codable {
        /// Runtime is installed and the device is shutdown.
        case ok
        /// Device exists in `simctl list` but its runtime is no longer
        /// `isAvailable` (Apple uninstalled the simulator runtime via
        /// Xcode, the runtime DMG was deleted, etc.).
        case stale
        /// Live state is `Booted` or some other non-shutdown value.
        /// Warm templates are supposed to be static artifacts — a
        /// booted warm template means `vch sim warm-template create`
        /// crashed mid-flight, the user manually booted it, or some
        /// external tool intervened. The clone-from-warm path will
        /// still work but the priming guarantees are weakened.
        case booted
        /// Name didn't match the strict `vch-warm[<device>:<runtime>]`
        /// pattern (somebody renamed it externally?). Listed for
        /// completeness; never returned for vch-managed names.
        case malformed
    }

    public init(
        name: String,
        deviceName: String,
        runtimeLabel: String,
        udid: String,
        state: String?,
        health: Health
    ) {
        self.name = name
        self.deviceName = deviceName
        self.runtimeLabel = runtimeLabel
        self.udid = udid
        self.state = state
        self.health = health
    }

    /// Stable JSON schema across `vch sim warm-template list --json`,
    /// `vch doctor --json`, and the bug-report tarball. Renaming a
    /// key here is a breaking change for downstream automation.
    private enum CodingKeys: String, CodingKey {
        case name
        case deviceName = "device"
        case runtimeLabel = "runtime"
        case udid
        case state
        case health
    }

    /// Single source of truth for the human-readable health column
    /// shown by `vch sim warm-template list` and `vch doctor`. Falls
    /// back to the live simctl `state` for the happy path so users
    /// see exactly what `simctl list` would show ("Shutdown" /
    /// "Booted" / etc.) instead of a vch synonym.
    public var humanHealthLabel: String {
        switch health {
        case .ok:        return state ?? "Shutdown"
        case .stale:     return "STALE (runtime missing)"
        case .booted:    return "BOOTED (expected Shutdown)"
        case .malformed: return "MALFORMED"
        }
    }
}

/// Parser for the warm-template name pattern.
///
/// The pattern is `vch-warm[<deviceName>:<runtimeLabel>]`. The device
/// name is everything between `[` and the **last** `:` — splitting on
/// the last colon means device names containing a colon (none today,
/// but defensively) survive the round trip. The runtime label is
/// everything after that colon up to the trailing `]`.
public enum WarmTemplateName {
    public static let prefix = "vch-warm["
    public static let suffix = "]"

    /// Build the canonical name. Always emits the dotted iOS form for
    /// the runtime so `vch test --runtime` and the warm-template name
    /// agree byte-for-byte.
    public static func format(deviceName: String, runtimeLabel: String) -> String {
        return "\(prefix)\(deviceName):\(runtimeLabel)\(suffix)"
    }

    /// Parse a simctl device name. Returns `nil` if the name doesn't
    /// match the strict pattern; callers should treat that as
    /// `Health.malformed` if they were expecting a vch-managed
    /// warm template.
    public static func parse(_ raw: String) -> (deviceName: String, runtimeLabel: String)? {
        guard raw.hasPrefix(prefix), raw.hasSuffix(suffix) else { return nil }
        let inner = raw.dropFirst(prefix.count).dropLast(suffix.count)
        guard let lastColon = inner.lastIndex(of: ":") else { return nil }
        let device = String(inner[..<lastColon])
        let runtime = String(inner[inner.index(after: lastColon)...])
        if device.isEmpty || runtime.isEmpty { return nil }
        return (device, runtime)
    }

    /// Cheap check used wherever we want to filter `simctl list`
    /// output to vch-managed warm templates without doing the full
    /// parse work first.
    public static func isWarmTemplateName(_ raw: String) -> Bool {
        return raw.hasPrefix(prefix) && raw.hasSuffix(suffix)
    }
}
