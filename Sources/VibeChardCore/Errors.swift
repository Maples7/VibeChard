import Foundation

/// All errors VibeChard surfaces to the CLI. Each variant carries enough
/// context to render a human-readable message *and* to map to a stable
/// `ExitCode`. Throwing a `VibeChardError` is the only allowed way to
/// terminate a Core operation.
public enum VibeChardError: Error, CustomStringConvertible {
    // Usage / validation (exit 2)
    case invalidTaskName(String, reason: String)
    case missingArgument(String)

    // Business state (exit 1)
    case worktreeAlreadyExists(path: String)
    case taskNotFound(name: String)
    case worktreeNotAGitRepository(path: String)
    case dirtyWorktree(path: String)
    case unmergedBranch(name: String)
    case stateFileCorrupt(path: String, underlying: String)
    case stateSchemaMismatch(found: Int, expected: Int)

    // External command failure (exit 3)
    case externalCommandFailed(cmd: String, exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case let .invalidTaskName(name, reason):
            return "invalid task name '\(name)': \(reason)"
        case let .missingArgument(name):
            return "missing argument: \(name)"
        case let .worktreeAlreadyExists(path):
            return "worktree already exists at \(path)"
        case let .taskNotFound(name):
            return "task not found: '\(name)'"
        case let .worktreeNotAGitRepository(path):
            return "not a git repository: \(path)"
        case let .dirtyWorktree(path):
            return "worktree has uncommitted changes: \(path) (use --force to remove anyway)"
        case let .unmergedBranch(name):
            return "branch '\(name)' is not fully merged (use --force --force to delete)"
        case let .stateFileCorrupt(path, underlying):
            return "state file corrupt at \(path): \(underlying) (run `vch repair`)"
        case let .stateSchemaMismatch(found, expected):
            return "state schema v\(found) does not match this vch (expected v\(expected)); run `vch repair`"
        case let .externalCommandFailed(cmd, code, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
            return "command failed (\(cmd), exit \(code))\(suffix)"
        }
    }
}
