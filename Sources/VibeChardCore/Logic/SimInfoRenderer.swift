import Foundation

/// JSON payload shape for `vch sim info --json` (#99).
///
/// Lives in Core so the wire format can be unit-tested without
/// shelling out to a `vch` subprocess (AGENTS.md #7 — `vch/` can't be
/// `@testable import`-ed, so encoding logic belongs here). The CLI is
/// reduced to "fetch bindings, fetch live simctl state, encode, print".
///
/// Pre-#99 shape was `{ "task": ..., "bound": null | { ... } }`. This
/// is a deliberate **breaking** rename: scripts that consumed the old
/// shape (parsing `.bound`) silently saw `null` once a task had
/// multi-binding state, which was the bug #99 was filed against.
public enum SimInfoRenderer {

    /// One row of the `bindings` array. Mirrors
    /// `TaskState.SimulatorRecord` plus the live `simctl` snapshot.
    public struct BindingRow: Encodable, Equatable, Sendable {
        public let cloneUDID: String
        public let sourceUDID: String
        public let name: String
        public let templateName: String?
        public let runtimeIdentifier: String?
        /// Human-readable simctl state, e.g. `"Shutdown"`, `"Booted"`,
        /// or the sentinel `"(missing — run `vch doctor`)"` when the
        /// device is no longer in `simctl list`.
        public let state: String
        /// `true` iff `simctl info` found this UDID.
        public let presentInSimctl: Bool

        public init(
            cloneUDID: String,
            sourceUDID: String,
            name: String,
            templateName: String?,
            runtimeIdentifier: String?,
            state: String,
            presentInSimctl: Bool
        ) {
            self.cloneUDID = cloneUDID
            self.sourceUDID = sourceUDID
            self.name = name
            self.templateName = templateName
            self.runtimeIdentifier = runtimeIdentifier
            self.state = state
            self.presentInSimctl = presentInSimctl
        }
    }

    /// Top-level payload. `bindings` is always an array, even when
    /// the task has no clone (it's then empty). The pre-#99
    /// `"bound": null` form is GONE — consumers must check
    /// `bindings.isEmpty`.
    public struct Payload: Encodable, Equatable, Sendable {
        public let task: String
        public let bindings: [BindingRow]

        public init(task: String, bindings: [BindingRow]) {
            self.task = task
            self.bindings = bindings
        }
    }

    /// Sentinel state string when `simctl info` returned a `SimDevice`
    /// but it carried no `state` field. Surfaced verbatim in JSON.
    public static let stateUnknown = "(unknown)"

    /// Sentinel state string when `simctl info` returned `nil` —
    /// either the device is not in `simctl list` at all, or it's
    /// listed but missing/unavailable. Tells the user where to look
    /// next.
    public static let stateMissing = "(missing — run `vch doctor`)"

    /// Resolve the `state` column for one binding from the optional
    /// live `SimDevice` snapshot. Same precedence as the CLI used to
    /// inline: a present device with a non-nil state wins, otherwise
    /// `stateUnknown` when present-but-state-less, otherwise
    /// `stateMissing` when the device is gone.
    public static func resolveState(live: SimDevice?) -> String {
        if let live, let state = live.state { return state }
        if live == nil { return stateMissing }
        return stateUnknown
    }

    /// Build a single `BindingRow` from a persisted record + the live
    /// simctl snapshot. Pure: no IO, no global state.
    public static func makeRow(
        record: TaskState.SimulatorRecord,
        live: SimDevice?
    ) -> BindingRow {
        BindingRow(
            cloneUDID: record.cloneUDID,
            sourceUDID: record.sourceUDID,
            name: record.name,
            templateName: record.templateName,
            runtimeIdentifier: record.runtimeIdentifier,
            state: resolveState(live: live),
            presentInSimctl: live != nil
        )
    }
}
