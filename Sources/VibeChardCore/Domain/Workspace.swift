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
        "\(parentDirectory)/\(repoName)-\(task.raw)"
    }

    public func statePath(for task: TaskName) -> String {
        "\(worktreePath(for: task))/.vch/state.json"
    }

    public func vchDir(for task: TaskName) -> String {
        "\(worktreePath(for: task))/.vch"
    }

    public func vchBinDir(for task: TaskName) -> String {
        "\(worktreePath(for: task))/.vch/bin"
    }

    public func agentBuildDir(for task: TaskName) -> String {
        "\(worktreePath(for: task))/.agent-build"
    }

    public func derivedDataDir(for task: TaskName) -> String {
        "\(agentBuildDir(for: task))/DerivedData"
    }

    public func moduleCacheDir(for task: TaskName) -> String {
        "\(agentBuildDir(for: task))/ModuleCache"
    }

    public func swiftpmCacheDir(for task: TaskName) -> String {
        "\(agentBuildDir(for: task))/SwiftPM"
    }

    public func resultBundlePath(for task: TaskName) -> String {
        "\(agentBuildDir(for: task))/Result.xcresult"
    }

    /// Path of the last `vch test` xcodebuild firehose, tee'd
    /// regardless of whether `--verbose` was passed (#9). Lives next
    /// to `state.json` so `vch rm` cleans it up automatically.
    public func lastTestLogPath(for task: TaskName) -> String {
        "\(vchDir(for: task))/last-test.log"
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
}
