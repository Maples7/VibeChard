import Foundation

/// Implements the `vch <name>` shorthand documented in Q9 (entry 5):
/// equivalent to `vch exec <name> -- $SHELL`.
///
/// Implementation strategy: `VchCLI.main()` peeks at `argv[1]` and, if
/// it's an unrecognized non-flag token, rewrites the argv to `["exec",
/// <name>, "--", $SHELL]` *before* handing off to the standard
/// ArgumentParser dispatch. This keeps the rest of the CLI surface
/// (and its `--help`) identical.
///
/// The "is this a known subcommand?" check is driven directly off
/// `TaskName.reserved` — there is only one list of reserved tokens in
/// the codebase, and it lives next to the rule that rejects them as
/// task names. A previous incarnation kept a second hardcoded copy
/// here in `vch`, which drifted and silently turned every freshly-added
/// subcommand into a broken `exec`-shaped invocation (#82 — `prune`
/// and `clean` both routed through this dispatcher in v0.5.0 instead
/// of dispatching to their `ParsableCommand`).
public enum TaskShortcutDispatcher {

    /// Returns a rewritten argv if the input is a sugar invocation,
    /// otherwise nil. `arguments` should NOT include argv[0] (vch
    /// itself); pass `Array(CommandLine.arguments.dropFirst())`.
    public static func rewriteIfSugar(_ arguments: [String], env: [String: String]) -> [String]? {
        guard let first = arguments.first else { return nil }
        if first.hasPrefix("-") { return nil }
        // Single source of truth: TaskName.reserved is the canonical
        // list of subcommand tokens. Anything in it must NOT be
        // rewritten as a task-name shortcut, because (a) it dispatches
        // to a real subcommand and (b) TaskName() would reject it
        // anyway.
        if TaskName.reserved.contains(first) { return nil }
        // Validation deferred to TaskName; if user typed gibberish it
        // surfaces as a familiar `invalidTaskName` error.

        let shell = env["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (shell?.isEmpty == false) ? shell! : "/bin/zsh"

        // Forward any extra args after the task name as additional
        // shell args (rare, but harmless).
        var rewritten = ["exec", first, "--", target]
        rewritten.append(contentsOf: arguments.dropFirst())
        return rewritten
    }
}
