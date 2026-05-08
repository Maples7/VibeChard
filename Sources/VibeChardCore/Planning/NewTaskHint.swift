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
    public static func message(
        stdoutIsTTY: Bool,
        env: [String: String]
    ) -> String? {
        guard stdoutIsTTY else { return nil }
        if let helper = env[helperEnv], !helper.isEmpty { return nil }
        if let suppress = env[suppressEnv]?.lowercased(),
           suppress == "0" || suppress == "false" || suppress == "no" {
            return nil
        }
        return hintMessage
    }
}
