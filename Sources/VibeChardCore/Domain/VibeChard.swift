import Foundation

/// Public version surface for VibeChard.
///
/// The version string is the single source of truth used by:
///   • `vch version` output
///   • Homebrew formula bumps (CI grep)
///   • State-file `schemaVersion` is *separate* (see `TaskState.swift`,
///     intentionally decoupled per Q5/Q10 of the v1 plan).
public enum VibeChard {
    /// Semantic version of the `vch` binary.
    /// Bumped manually in `git tag v*` releases. The release workflow
    /// fails fast if this constant doesn't match the pushed tag.
    public static let version = "0.3.0"

    /// Marketing tagline. Surfaces in `vch help` and `vch version --json`.
    public static let tagline =
        "Apple-only parallel worktree orchestrator for AI coding agents."
}
