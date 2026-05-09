import Foundation

/// Encapsulates the per-task path layout decisions. Centralizing them
/// here makes the layout testable independent of FileSystem/git, and
/// keeps `<wt>/.vch/...` and `<wt>/.agent-build/...` conventions in one
/// place so downstream commands (M2 shim, M4 build) can refer here.
public struct Workspace: Equatable, Sendable {
    /// Absolute path of the repo's main worktree.
    public let mainWorktreePath: String
    /// Absolute path of the directory that *contains* the main worktree.
    /// Per-task worktrees are created as siblings here.
    public let parentDirectory: String
    /// The leaf name of `mainWorktreePath` (e.g. "BeanLedger"), used as
    /// the prefix for sibling worktree paths.
    public let repoName: String

    public init(mainWorktreePath: String) {
        self.mainWorktreePath = Self.normalize(mainWorktreePath)
        let url = URL(fileURLWithPath: self.mainWorktreePath)
        self.parentDirectory = url.deletingLastPathComponent().path
        self.repoName = url.lastPathComponent
    }

    public init(mainWorktreePath: String, parentDirectory: String, repoName: String) {
        self.mainWorktreePath = Self.normalize(mainWorktreePath)
        self.parentDirectory = parentDirectory
        self.repoName = repoName
    }

    /// Sibling worktree path for a task: `<parent>/<repo>-<task>`.
    public func worktreePath(for task: TaskName) -> String {
        PathOps.join(parentDirectory, "\(repoName)-\(task.raw)")
    }

    public func statePath(for task: TaskName) -> String {
        PathOps.join(worktreePath(for: task), Self.stateJsonRelativePath)
    }

    public func vchDir(for task: TaskName) -> String {
        PathOps.join(worktreePath(for: task), ".vch")
    }

    public func vchBinDir(for task: TaskName) -> String {
        PathOps.join(worktreePath(for: task), ".vch/bin")
    }

    public func agentBuildDir(for task: TaskName) -> String {
        PathOps.join(worktreePath(for: task), ".agent-build")
    }

    public func derivedDataDir(for task: TaskName) -> String {
        PathOps.join(agentBuildDir(for: task), "DerivedData")
    }

    public func moduleCacheDir(for task: TaskName) -> String {
        PathOps.join(agentBuildDir(for: task), "ModuleCache")
    }

    public func swiftpmCacheDir(for task: TaskName) -> String {
        PathOps.join(agentBuildDir(for: task), "SwiftPM")
    }

    /// Subdirectory of `swiftpmCacheDir(for:)` that holds the
    /// content-addressed bare git mirrors xcodebuild populates when
    /// resolving SwiftPM dependencies. This is the only portion of
    /// the SwiftPM tree that is portable across worktrees (#55):
    /// `workspace-state.json` is portable too but `checkouts/` has
    /// stale absolute back-pointers, so we restrict
    /// `--seed-spm-from` to this dir alone.
    public func swiftpmRepositoriesDir(for task: TaskName) -> String {
        PathOps.join(swiftpmCacheDir(for: task), "repositories")
    }

    public func resultBundlePath(for task: TaskName) -> String {
        PathOps.join(agentBuildDir(for: task), "Result.xcresult")
    }

    /// Path of the last `vch test` xcodebuild firehose, tee'd
    /// regardless of whether `--verbose` was passed (#9). Lives next
    /// to `state.json` so `vch rm` cleans it up automatically.
    public func lastTestLogPath(for task: TaskName) -> String {
        PathOps.join(vchDir(for: task), "last-test.log")
    }

    /// Path of the last `vch build` xcodebuild firehose, tee'd
    /// regardless of whether `--verbose` was passed (#48). Mirrors
    /// `lastTestLogPath(for:)`.
    public func lastBuildLogPath(for task: TaskName) -> String {
        PathOps.join(vchDir(for: task), "last-build.log")
    }

    /// Recognize a worktree path as belonging to vch (i.e. the leaf is
    /// `<repoName>-<something>`). Returns the task-name suffix or nil.
    public func taskNameRaw(forWorktreePath path: String) -> String? {
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        let prefix = "\(repoName)-"
        guard leaf.hasPrefix(prefix), leaf.count > prefix.count else { return nil }
        return String(leaf.dropFirst(prefix.count))
    }

    private static func normalize(_ p: String) -> String {
        // Strip trailing slash for stable equality checks.
        if p.hasSuffix("/") && p != "/" { return String(p.dropLast()) }
        return p
    }

    // MARK: - Layout constants
    //
    // Single source of truth for the worktree-relative paths vch
    // owns. Used by callers that iterate worktree contents *before*
    // they have a `TaskName` in scope (Doctor, BugReport,
    // TaskService porcelain scans), where the per-task helpers
    // above can't apply. Anything that does have a `TaskName`
    // should still call `statePath(for:)` / `vchDir(for:)` /
    // `agentBuildDir(for:)` — those compose these constants.

    /// Per-worktree state file, relative to the worktree root.
    public static let stateJsonRelativePath = ".vch/state.json"

    /// Per-worktree last-test log, relative to the worktree root.
    /// Mirrors `lastTestLogPath(for:)` for callers iterating worktrees
    /// without a `TaskName` in scope (BugReport).
    public static let lastTestLogRelativePath = ".vch/last-test.log"

    /// Per-worktree last-build log, relative to the worktree root.
    /// Mirrors `lastBuildLogPath(for:)` for callers iterating worktrees
    /// without a `TaskName` in scope (BugReport).
    public static let lastBuildLogRelativePath = ".vch/last-build.log"

    /// Worktree-relative directory prefixes that vch manages
    /// (`.vch/` for state, `.agent-build/` for caches). Callers
    /// scanning a worktree should skip entries with these prefixes
    /// to avoid touching vch's own scratch directories.
    public static let managedDirPrefixes: [String] = [".vch/", ".agent-build/"]
}
