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
    public static let version = "1.2.0"

    /// Canonical public repository URL used for version-pinned docs.
    public static let repositoryURL = "https://github.com/Maples7/VibeChard"

    /// Marketing tagline. Surfaces in `vch help` and `vch version --json`.
    public static let tagline =
        "Apple-only parallel worktree orchestrator for AI coding agents."

    /// Agent-facing operational guide, versioned with each release.
    public static let agentRunbookPath = "docs/agent-runbook.md"

    /// Tag-pinned runbook URL for this binary version. Read-only; value is
    /// stable for a given binary.
    public static var agentRunbookURL: String {
        "\(repositoryURL)/blob/v\(version)/\(agentRunbookPath)"
    }

    /// Homebrew-installed runbook location. This is a shell expression
    /// because the concrete prefix is `/opt/homebrew` or `/usr/local`.
    public static let homebrewAgentRunbookPath =
        "$(brew --prefix vch)/share/doc/vch/agent-runbook.md"
}
