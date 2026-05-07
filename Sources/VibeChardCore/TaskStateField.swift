import Foundation

/// Stable, machine-readable lookup for `vch state --field <dotted>` (#8).
///
/// Centralizes the dotted-path → scalar-string mapping so scripts and
/// agents can rely on a documented surface instead of grep-ing
/// state.json by hand. Keep additions append-only — removing a field
/// is a breaking change for downstream automation.
public enum TaskStateField {

    /// All field names this version of vch knows. Useful for
    /// `vch state <task> --field` validation and for future
    /// `--list-fields` discovery.
    public static let known: [String] = [
        "name",
        "branch",
        "path",
        "base",
        "schema",
        "scheme",
        "createdAt",
        "simulator.udid",
        "simulator.cloneUDID",
        "simulator.sourceUDID",
        "simulator.name",
        "simulator.templateName",
        "simulator.runtime",
        "simulator.runtimeIdentifier",
        "lastBuild.success",
        "lastBuild.finishedAt",
        "lastBuild.durationSeconds",
        "lastTest.success",
        "lastTest.finishedAt",
        "lastTest.durationSeconds",
        "lastTest.resultBundlePath",
        "lastExec.command",
        "lastExec.startedAt",
        "lastExec.exitedAt",
        "lastExec.exitCode",
    ]

    /// Three-state result so the caller can distinguish "this field
    /// name is unknown" (exit 2 / usage) from "the field is known but
    /// not currently set" (exit 1 / business). Mirrors `git config
    /// --get`'s convention.
    public enum LookupResult: Equatable {
        case value(String)
        case unset      // field is part of the schema but not populated
        case unknown    // field name not recognized at all
    }

    /// Look up a dotted path against `state` + the worktree path.
    /// `worktreePath` is folded in so `path` is queryable without
    /// reaching back into `Workspace`.
    public static func lookup(
        _ field: String,
        in state: TaskState,
        worktreePath: String
    ) -> LookupResult {
        switch field {
        case "name":           return .value(state.name)
        case "branch":         return .value(state.branch)
        case "path":           return .value(worktreePath)
        case "base":           return .value(state.baseRef)
        case "schema":         return .value(String(state.schemaVersion))
        case "scheme":         return optional(state.scheme)
        case "createdAt":      return .value(iso8601(state.createdAt))

        case "simulator.udid", "simulator.cloneUDID":
            return optional(state.simulator?.cloneUDID)
        case "simulator.sourceUDID":
            return optional(state.simulator?.sourceUDID)
        case "simulator.name":
            return optional(state.simulator?.name)
        case "simulator.templateName":
            return optional(state.simulator?.templateName)
        case "simulator.runtime":
            // Friendly form: `iOS 18.5`. Falls back to the raw
            // identifier when only that is known. Unset when neither
            // exists (legacy state with no runtime info at all).
            if let v = state.simulator?.runtimeIdentifier
                .flatMap({ SimRuntimeVersion.parse(runtimeIdentifier: $0) }) {
                return .value("iOS \(v.major).\(v.minor)")
            }
            return optional(state.simulator?.runtimeIdentifier)
        case "simulator.runtimeIdentifier":
            return optional(state.simulator?.runtimeIdentifier)

        case "lastBuild.success":
            return optional(state.lastBuild.map { $0.success ? "true" : "false" })
        case "lastBuild.finishedAt":
            return optional(state.lastBuild.map { iso8601($0.finishedAt) })
        case "lastBuild.durationSeconds":
            return optional(state.lastBuild.map { String(format: "%.3f", $0.durationSeconds) })

        case "lastTest.success":
            return optional(state.lastTest.map { $0.success ? "true" : "false" })
        case "lastTest.finishedAt":
            return optional(state.lastTest.map { iso8601($0.finishedAt) })
        case "lastTest.durationSeconds":
            return optional(state.lastTest.map { String(format: "%.3f", $0.durationSeconds) })
        case "lastTest.resultBundlePath":
            return optional(state.lastTest?.resultBundlePath)

        case "lastExec.command":
            return optional(state.lastExec?.command)
        case "lastExec.startedAt":
            return optional(state.lastExec.map { iso8601($0.startedAt) })
        case "lastExec.exitedAt":
            return optional(state.lastExec?.exitedAt.map(iso8601))
        case "lastExec.exitCode":
            return optional(state.lastExec?.exitCode.map { String($0) })

        default:
            return .unknown
        }
    }

    private static func optional(_ value: String?) -> LookupResult {
        if let value { return .value(value) }
        return .unset
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
