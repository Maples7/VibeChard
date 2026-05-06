import Foundation

/// One entry from `git worktree list --porcelain`.
public struct WorktreeEntry: Equatable, Sendable {
    public let path: String
    public let head: String?
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool

    public init(path: String, head: String? = nil, branch: String? = nil, isBare: Bool = false, isDetached: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
    }
}

/// Status hints used by `vch remove`.
public struct WorktreeStatus: Equatable, Sendable {
    public let isDirty: Bool

    public init(isDirty: Bool) {
        self.isDirty = isDirty
    }
}

/// Narrow git operations VibeChard needs. Implementations may shell out
/// to `/usr/bin/git` (production) or substitute fakes in tests.
public protocol GitClient: Sendable {
    /// `git worktree list --porcelain` parsed into entries.
    /// Path of the current repository's main worktree is the first entry.
    func worktreeList(repoCwd: String) throws -> [WorktreeEntry]

    /// `git worktree add <path> -b <branch> [<base>]` — branch must not
    /// already exist. If it does, callers should use `worktreeAddExisting`.
    func worktreeAddNewBranch(repoCwd: String, path: String, branch: String, base: String) throws

    /// `git worktree add <path> <branch>` — for a branch that already exists.
    func worktreeAddExisting(repoCwd: String, path: String, branch: String) throws

    /// `git worktree remove [--force] <path>`.
    func worktreeRemove(repoCwd: String, path: String, force: Bool) throws

    /// `git worktree prune`.
    func worktreePrune(repoCwd: String) throws

    func branchExists(repoCwd: String, name: String) throws -> Bool

    /// Plain `git branch -d`. Throws `unmergedBranch` if git refuses; the
    /// caller decides whether to escalate to `branchDeleteForce`.
    func branchDelete(repoCwd: String, name: String) throws

    /// `git branch -D` — force-delete even if unmerged.
    func branchDeleteForce(repoCwd: String, name: String) throws

    /// Returns `true` if `git status --porcelain` produced any output.
    func statusIsDirty(worktreeCwd: String) throws -> Bool

    /// `git rev-parse --short HEAD`. Used to record `baseRef` in state.json.
    func revParseHEADShort(repoCwd: String) throws -> String

    /// Append `patterns` to the repo's `info/exclude` file (resolved via
    /// `git rev-parse --git-path info/exclude`). Note: for linked
    /// worktrees git resolves this to the *main* repo's
    /// `.git/info/exclude`, which is shared across all worktrees — that's
    /// the right place for vch's `.vch/` and `.agent-build/` patterns
    /// since they're vch's own scratch dirs and never wanted by anyone.
    /// Idempotent: a pattern already present is not duplicated.
    func appendLocalExcludes(worktreeCwd: String, patterns: [String]) throws
}

// MARK: - Real implementation

public struct DiskGitClient: GitClient {
    private let runner: ProcessRunner
    private let gitPath: String

    public init(runner: ProcessRunner = DiskProcessRunner(), gitPath: String = "/usr/bin/git") {
        self.runner = runner
        self.gitPath = gitPath
    }

    public func worktreeList(repoCwd: String) throws -> [WorktreeEntry] {
        let result = try runner.run(gitPath, args: ["worktree", "list", "--porcelain"], cwd: repoCwd)
        try requireSuccess(result, label: "git worktree list --porcelain")
        return PorcelainParser.parseWorktreeList(result.stdout)
    }

    public func worktreeAddNewBranch(repoCwd: String, path: String, branch: String, base: String) throws {
        let result = try runner.run(gitPath, args: ["worktree", "add", "-b", branch, path, base], cwd: repoCwd)
        try requireSuccess(result, label: "git worktree add -b \(branch) \(path)")
    }

    public func worktreeAddExisting(repoCwd: String, path: String, branch: String) throws {
        let result = try runner.run(gitPath, args: ["worktree", "add", path, branch], cwd: repoCwd)
        try requireSuccess(result, label: "git worktree add \(path) \(branch)")
    }

    public func worktreeRemove(repoCwd: String, path: String, force: Bool) throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        let result = try runner.run(gitPath, args: args, cwd: repoCwd)
        try requireSuccess(result, label: "git \(args.joined(separator: " "))")
    }

    public func worktreePrune(repoCwd: String) throws {
        let result = try runner.run(gitPath, args: ["worktree", "prune"], cwd: repoCwd)
        try requireSuccess(result, label: "git worktree prune")
    }

    public func branchExists(repoCwd: String, name: String) throws -> Bool {
        let result = try runner.run(
            gitPath,
            args: ["show-ref", "--verify", "--quiet", "refs/heads/\(name)"],
            cwd: repoCwd
        )
        // 0 = exists, 1 = doesn't exist. Anything else is a real failure.
        switch result.exitCode {
        case 0: return true
        case 1: return false
        default:
            throw VibeChardError.externalCommandFailed(
                cmd: "git show-ref --verify refs/heads/\(name)",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    public func branchDelete(repoCwd: String, name: String) throws {
        let result = try runner.run(gitPath, args: ["branch", "-d", name], cwd: repoCwd)
        if result.exitCode == 0 { return }
        // git refuses to delete unmerged branches with exit 1 and a stderr
        // mentioning "not fully merged". Map that to a stable error.
        if result.stderr.contains("not fully merged") {
            throw VibeChardError.unmergedBranch(name: name)
        }
        throw VibeChardError.externalCommandFailed(
            cmd: "git branch -d \(name)",
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }

    public func branchDeleteForce(repoCwd: String, name: String) throws {
        let result = try runner.run(gitPath, args: ["branch", "-D", name], cwd: repoCwd)
        try requireSuccess(result, label: "git branch -D \(name)")
    }

    public func statusIsDirty(worktreeCwd: String) throws -> Bool {
        let result = try runner.run(gitPath, args: ["status", "--porcelain"], cwd: worktreeCwd)
        try requireSuccess(result, label: "git status --porcelain")
        return !result.stdoutTrimmed.isEmpty
    }

    public func revParseHEADShort(repoCwd: String) throws -> String {
        let result = try runner.run(gitPath, args: ["rev-parse", "--short", "HEAD"], cwd: repoCwd)
        try requireSuccess(result, label: "git rev-parse --short HEAD")
        return result.stdoutTrimmed
    }

    public func appendLocalExcludes(worktreeCwd: String, patterns: [String]) throws {
        // Resolve the per-worktree exclude file. For linked worktrees this
        // lives under `<main>/.git/worktrees/<task>/info/exclude` and `git
        // rev-parse --git-path` gives us the right answer regardless.
        let pathResult = try runner.run(
            gitPath,
            args: ["rev-parse", "--git-path", "info/exclude"],
            cwd: worktreeCwd
        )
        try requireSuccess(pathResult, label: "git rev-parse --git-path info/exclude")
        var excludePath = pathResult.stdoutTrimmed
        if excludePath.isEmpty { return }
        // git may return a relative path; resolve against the worktree cwd.
        if !excludePath.hasPrefix("/") {
            excludePath = "\(worktreeCwd)/\(excludePath)"
        }

        // Read existing contents (file may not exist) and append only the
        // patterns that aren't already on a line on their own.
        let fm = FileManager.default
        var existing = ""
        if fm.fileExists(atPath: excludePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: excludePath)),
           let str = String(data: data, encoding: .utf8) {
            existing = str
        }
        let existingLines = Set(existing.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init))

        var toAppend: [String] = []
        for p in patterns where !existingLines.contains(p) {
            toAppend.append(p)
        }
        guard !toAppend.isEmpty else { return }

        // Ensure the directory exists.
        let parent = (excludePath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        var newContent = existing
        if !newContent.isEmpty && !newContent.hasSuffix("\n") {
            newContent.append("\n")
        }
        newContent.append("# Added by vch — local-only excludes\n")
        for p in toAppend {
            newContent.append(p)
            newContent.append("\n")
        }
        try newContent.write(to: URL(fileURLWithPath: excludePath), atomically: true, encoding: .utf8)
    }

    private func requireSuccess(_ result: ProcessResult, label: String) throws {
        if !result.succeeded {
            throw VibeChardError.externalCommandFailed(
                cmd: label,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }
}

// MARK: - Parser

/// Parser for `git worktree list --porcelain`. Public so unit tests can
/// exercise it directly without spawning git.
public enum PorcelainParser {
    /// Format reference: `man git-worktree`. Each entry is a block of
    /// `key value`-ish lines terminated by a blank line. Fields we care
    /// about: `worktree`, `HEAD`, `branch`, `bare`, `detached`.
    public static func parseWorktreeList(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var path: String?
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false

        func flush() {
            guard let p = path else { return }
            entries.append(WorktreeEntry(
                path: p,
                head: head,
                branch: branch,
                isBare: isBare,
                isDetached: isDetached
            ))
            path = nil; head = nil; branch = nil
            isBare = false; isDetached = false
        }

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            // Two-token form: `key value`. Single-token form: `bare`/`detached`.
            if let spaceIdx = line.firstIndex(of: " ") {
                let key = String(line[..<spaceIdx])
                let value = String(line[line.index(after: spaceIdx)...])
                switch key {
                case "worktree": path = value
                case "HEAD":     head = value
                case "branch":   branch = stripRefsHeads(value)
                default: break
                }
            } else {
                switch line {
                case "bare":     isBare = true
                case "detached": isDetached = true
                default: break
                }
            }
        }
        flush()
        return entries
    }

    private static func stripRefsHeads(_ ref: String) -> String {
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }
}
