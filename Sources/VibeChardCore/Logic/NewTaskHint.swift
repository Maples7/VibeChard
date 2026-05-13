import Foundation

/// Decides whether `vch new` should print a one-line stderr hint
/// pointing the user at `vch shellenv` (so `vch_new <name>` does the
/// auto-cd they probably wanted).
///
/// Logic kept in Core so the policy is unit-testable without touching
/// real terminals or the environment. The CLI layer is responsible
/// only for detecting the TTY and forwarding `ProcessInfo`.
public enum NewTaskHint {
    /// Set to `0` (or `false`) to silence the hint. Useful for CI.
    public static let suppressEnv = "VCH_NEW_HINT"
    /// Set automatically by the `vch shellenv` output once sourced —
    /// presence implies the user already has the helpers.
    public static let helperEnv = "VCH_SHELL_HELPER"

    /// The hint string. Single line, prefixed with the same `→` arrow
    /// other status lines use.
    public static let hintMessage = """
    → tip: install shell helpers with `eval "$(vch shellenv)"` — then \
    `vch_new <name>` creates the worktree AND cds into it. Silence with \
    VCH_NEW_HINT=0.
    """

    /// Returns the hint to print to stderr, or `nil` to stay silent.
    ///
    /// Stays silent when:
    ///   • stdout isn't a TTY (caller is scripting, output captured)
    ///   • `VCH_SHELL_HELPER` is already set (helpers are sourced)
    ///   • `VCH_NEW_HINT` is `0` / `false` (explicit opt-out)
    ///   • `adoptCurrent == true` — the user is already standing in the
    ///     worktree they just adopted, there is no auto-cd benefit to
    ///     advertise. Suppressing here keeps decision logic in Core so
    ///     it's unit-testable (AGENTS.md discipline #7). (#98 follow-up)
    ///   • `execProvided == true` — about to `execve` into the agent,
    ///     any hint we print would be lost.
    ///   • `cdProvided == true` — `--cd` puts vch into machine-readable
    ///     mode (the wrapper consumes stdout); a banner on stderr would
    ///     pollute that contract.
    public static func message(
        stdoutIsTTY: Bool,
        env: [String: String],
        adoptCurrent: Bool = false,
        execProvided: Bool = false,
        cdProvided: Bool = false
    ) -> String? {
        if adoptCurrent || execProvided || cdProvided { return nil }
        guard stdoutIsTTY else { return nil }
        if let helper = env[helperEnv], !helper.isEmpty { return nil }
        if let suppress = env[suppressEnv]?.lowercased(),
           suppress == "0" || suppress == "false" || suppress == "no" {
            return nil
        }
        return hintMessage
    }
}
