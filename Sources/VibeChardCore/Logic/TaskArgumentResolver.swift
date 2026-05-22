import Foundation

/// Resolves task arguments for commands that can infer the current task
/// from a vch-managed linked worktree.
public enum TaskArgumentResolver {
    public static func resolve(
        explicit: String?,
        current: TaskName?
    ) throws -> TaskName {
        if let explicit, !explicit.isEmpty {
            return try TaskName(explicit)
        }
        if let current {
            return current
        }
        throw VibeChardError.missingArgument("<name>")
    }
}