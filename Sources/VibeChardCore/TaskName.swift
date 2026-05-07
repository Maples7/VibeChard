import Foundation

/// A validated VibeChard task name. Used as the leaf of the worktree path
/// (`<repo>-<name>`) and the suffix of the branch (`agent/<name>`), so
/// constraints are intentionally tighter than `git check-ref-format`:
///
///   • non-empty, ≤ 64 characters
///   • starts with `[a-zA-Z0-9]`
///   • the remaining characters are `[a-zA-Z0-9._-]` only
///   • does not match a reserved subcommand name
///   • does not start with `-` (reserved for flags)
///
/// `/` is rejected even though git allows it in branch names, because
/// the worktree path uses `<repo>-<name>` and `/` would create nested
/// directories that confuse `git worktree list` parsing.
public struct TaskName: Hashable, Sendable {
    public let raw: String

    /// Subcommand and flag names that may never be used as a task name.
    /// Keep in sync with `AGENTS.md` rule #8.
    public static let reserved: Set<String> = [
        "new", "list", "ls", "path", "exec", "open",
        "build", "test", "run", "logs", "sim", "state", "completions",
        "remove", "rm", "repair", "doctor", "land",
        "shellenv", "version", "help",
    ]

    public static let maxLength = 64

    public init(_ raw: String) throws {
        if raw.isEmpty {
            throw VibeChardError.invalidTaskName(raw, reason: "name must not be empty")
        }
        if raw.count > Self.maxLength {
            throw VibeChardError.invalidTaskName(
                raw,
                reason: "name must be ≤ \(Self.maxLength) characters"
            )
        }
        if raw.hasPrefix("-") {
            throw VibeChardError.invalidTaskName(
                raw,
                reason: "name must not start with '-' (reserved for flags)"
            )
        }
        if Self.reserved.contains(raw) {
            throw VibeChardError.invalidTaskName(
                raw,
                reason: "'\(raw)' is a reserved subcommand"
            )
        }
        guard let firstScalar = raw.unicodeScalars.first,
              Self.firstCharSet.contains(firstScalar) else {
            throw VibeChardError.invalidTaskName(
                raw,
                reason: "name must start with a letter or digit"
            )
        }
        for scalar in raw.unicodeScalars.dropFirst() {
            guard Self.tailCharSet.contains(scalar) else {
                throw VibeChardError.invalidTaskName(
                    raw,
                    reason: "name may only contain letters, digits, '.', '_', '-'"
                )
            }
        }
        self.raw = raw
    }

    /// Branch name VibeChard creates for this task: `agent/<raw>`.
    public var branchName: String { "agent/\(raw)" }

    private static let firstCharSet: CharacterSet = {
        var set = CharacterSet.alphanumerics
        // `CharacterSet.alphanumerics` covers all Unicode alphanumerics; we
        // restrict to ASCII below in the tail set, but the first-char check
        // is enough on its own because the tail set is ASCII-only.
        set.formIntersection(CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        ))
        return set
    }()

    private static let tailCharSet = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
}

extension TaskName: CustomStringConvertible {
    public var description: String { raw }
}
