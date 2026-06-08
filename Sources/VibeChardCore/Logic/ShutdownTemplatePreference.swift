import Foundation

/// Decides whether vch may shut a `Booted` warm template down before
/// `simctl clone`, combining the explicit `--shutdown-template` flag
/// with a persistable opt-in environment variable. (#164)
///
/// Background: the default is conservative — vch never touches a shared
/// warm template on its own (hard rule #9), so a Booted template makes
/// the next `vch build` / `vch test` / `vch run` fail with
/// `simulatorTemplateBooted` until the user passes `--shutdown-template`.
/// For workflows that interleave manual `simctl boot` UI checks with vch
/// builds, retyping the flag every invocation — sometimes just to clear
/// a template a *previous session* left Booted — is a papercut.
///
/// `VCH_SHUTDOWN_TEMPLATE_ON_CLONE` lets an informed user opt in once
/// (shell profile, repo `.envrc`, CI) so `--shutdown-template` applies
/// by default, without changing the global default for everyone else.
/// Shutting a template down is idempotent and non-destructive (it only
/// discards a warm-boot optimisation), which is why this knob is scoped
/// to the template, never to a per-task clone.
///
/// Lives in `Logic/` (no IO) so the precedence rule is unit-testable
/// without a real environment — the CLI forwards `ProcessInfo`
/// (AGENTS.md discipline #7), mirroring `NewTaskHint` / `OpenService`.
public enum ShutdownTemplatePreference {
    /// Env var that makes `--shutdown-template` the default for clone
    /// operations. Part of the documented `VCH_*` set (hard rule #7).
    public static let optInEnv = "VCH_SHUTDOWN_TEMPLATE_ON_CLONE"

    /// Whether vch should shut a Booted warm template down before
    /// cloning. The explicit `--shutdown-template` flag always wins;
    /// otherwise the `VCH_SHUTDOWN_TEMPLATE_ON_CLONE` opt-in decides.
    public static func resolve(flag: Bool, env: [String: String]) -> Bool {
        if flag { return true }
        return isOptedIn(env[optInEnv])
    }

    /// Truthy parse for the opt-in var. Accepts `1` / `true` / `yes` /
    /// `on` (case-insensitive, trimmed); everything else — including an
    /// unset or empty value — leaves the conservative default in place.
    static func isOptedIn(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespaces).lowercased(),
              !value.isEmpty else {
            return false
        }
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }
}
