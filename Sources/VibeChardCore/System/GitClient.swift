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

    /// `git ls-files --others --exclude-standard -z` parsed into
    /// repo-relative paths. Excludes both tracked files and anything
    /// matched by `.gitignore` / `.git/info/exclude` / global excludes.
    /// Used by `vch new --copy-untracked`.
    func listUntrackedFiles(worktreeCwd: String) throws -> [String]

    /// `git symbolic-ref --short -q HEAD`. Returns the branch name the
    /// worktree's HEAD currently points at, or `nil` for a detached
    /// HEAD. Never throws on detached HEAD — only on hard git failures.
    /// Used by `vch new` to record the base branch and by `vch land`
    /// to verify the user is on the expected `--into` branch. (#7)
    func currentBranch(repoCwd: String) throws -> String?

    /// `git diff --name-only <base>..<head>` parsed into repo-relative
    /// paths. Used by `vch land` to compute the merge's footprint and
    /// to detect overlap with a dirty main worktree. (#7)
    func diffNamesOnly(repoCwd: String, base: String, head: String) throws -> [String]

    /// `git rev-list --count <base>..<head>` — number of commits on
    /// `head` that aren't yet on `base`. `0` means the merge would be
    /// a no-op. (#7)
    func revListCount(repoCwd: String, base: String, head: String) throws -> Int

    /// Subject line of the most recent non-merge commit on `branch`,
    /// via `git log --no-merges --format=%s -n 1 <branch>`. Returns
    /// `nil` if the branch has no non-merge commits at all. Used to
    /// build `vch land`'s default merge commit message. (#7)
    func lastNonMergeSubject(repoCwd: String, branch: String) throws -> String?

    /// Repo-relative paths reported as changed by `git status
    /// --porcelain` (modified, added, deleted, renamed, untracked).
    /// Used by `vch land` to detect overlap between a dirty main
    /// worktree and the task branch's diff. (#7)
    func statusPaths(worktreeCwd: String) throws -> [String]

    /// Repo-relative paths currently in an unresolved merge state.
    /// Used by `vch land` after a failed merge to distinguish a real
    /// merge conflict from other git failures such as `--ff-only`
    /// refusal. (#140)
    func unmergedPaths(worktreeCwd: String) throws -> [String]

    /// Run a merge in `repoCwd` with the requested mode. Throws
    /// `externalCommandFailed` on git failure (conflict, refused FF,
    /// dirty index, etc.). For `.squash`, runs `git merge --squash`
    /// followed by `git commit -m <message>`. (#7)
    func merge(repoCwd: String, branch: String, mode: GitMergeMode, message: String) throws

    /// `git fetch <remote> <branch>`. Updates the local copy of
    /// `<remote>/<branch>`. Used by `vch sync` before resolving the
    /// base ref so the rebase / merge sees up-to-date upstream
    /// commits. Throws `externalCommandFailed` on any non-zero
    /// exit (network unreachable, unknown remote, unknown ref). (#25)
    func fetch(repoCwd: String, remote: String, branch: String) throws

    /// `git rebase <onto>` run in `worktreeCwd`. Throws
    /// `externalCommandFailed` on conflict (caller maps to
    /// `syncRebaseConflict`) or any other rebase failure. Stderr
    /// is the raw git output the caller has already streamed. (#25)
    func rebase(worktreeCwd: String, onto: String) throws

    /// `git config --get branch.<branch>.remote`. Returns the
    /// remote name (e.g. `origin`) configured to track `branch`,
    /// or `nil` if the branch has no upstream remote (purely local).
    /// Never throws on "unset"; only on hard git failures. (#25)
    func upstreamRemote(repoCwd: String, branch: String) throws -> String?

    /// `git rev-parse <ref>`. Returns the full 40-char commit SHA
    /// `<ref>` resolves to. Throws `externalCommandFailed` if `<ref>`
    /// is unknown (caller decides whether to surface the git stderr
    /// or remap to a domain error). Used by `vch sync` to record the
    /// resolved base SHA in `lastSync.baseSHA`. (#25)
    func revParse(repoCwd: String, ref: String) throws -> String

    /// `git push <remote> <branch>` run in `repoCwd`. Throws
    /// `externalCommandFailed` on any non-zero exit (network down,
    /// non-fast-forward, unknown remote, missing upstream perms).
    /// Used by `vch land --push` after a successful merge — the
    /// caller decides whether to surface the failure as a warning
    /// (the merge already landed locally) or escalate. (#49)
    func push(repoCwd: String, remote: String, branch: String) throws
}

/// Merge strategy for `GitClient.merge`. Mirrors `vch land`'s
/// `--no-ff|--ff-only|--squash` flags. (#7)
public enum GitMergeMode: String, Sendable, Equatable {
    /// `git merge --no-ff -m <msg> <branch>` — always create a merge commit.
    case noFF
    /// `git merge --ff-only <branch>` — refuse if a merge commit would be needed.
    case ffOnly
    /// `git merge --squash <branch>` then `git commit -m <msg>`.
    case squash
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
            excludePath = PathOps.join(worktreeCwd, excludePath)
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

    public func listUntrackedFiles(worktreeCwd: String) throws -> [String] {
        // -z separates entries with NUL so paths with newlines / quotes
        // come through verbatim. --exclude-standard honors .gitignore +
        // .git/info/exclude + ~/.config/git/ignore.
        let result = try runner.run(
            gitPath,
            args: ["ls-files", "--others", "--exclude-standard", "-z"],
            cwd: worktreeCwd
        )
        try requireSuccess(result, label: "git ls-files --others --exclude-standard -z")
        // stdout is a NUL-terminated list; split on NUL and drop the
        // trailing empty token.
        return result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public func currentBranch(repoCwd: String) throws -> String? {
        let result = try runner.run(
            gitPath,
            args: ["symbolic-ref", "--short", "-q", "HEAD"],
            cwd: repoCwd
        )
        // 0 = on a branch (stdout is the branch name), 1 = detached HEAD,
        // anything else is a real failure.
        switch result.exitCode {
        case 0:
            let name = result.stdoutTrimmed
            return name.isEmpty ? nil : name
        case 1:
            return nil
        default:
            throw VibeChardError.externalCommandFailed(
                cmd: "git symbolic-ref --short -q HEAD",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    public func diffNamesOnly(repoCwd: String, base: String, head: String) throws -> [String] {
        let result = try runner.run(
            gitPath,
            args: ["diff", "--name-only", "-z", "\(base)..\(head)"],
            cwd: repoCwd
        )
        try requireSuccess(result, label: "git diff --name-only -z \(base)..\(head)")
        return result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public func revListCount(repoCwd: String, base: String, head: String) throws -> Int {
        let result = try runner.run(
            gitPath,
            args: ["rev-list", "--count", "\(base)..\(head)"],
            cwd: repoCwd
        )
        try requireSuccess(result, label: "git rev-list --count \(base)..\(head)")
        return Int(result.stdoutTrimmed) ?? 0
    }

    public func lastNonMergeSubject(repoCwd: String, branch: String) throws -> String? {
        let result = try runner.run(
            gitPath,
            args: ["log", "--no-merges", "--format=%s", "-n", "1", branch],
            cwd: repoCwd
        )
        try requireSuccess(result, label: "git log --no-merges --format=%s -n 1 \(branch)")
        let subject = result.stdoutTrimmed
        return subject.isEmpty ? nil : subject
    }

    public func statusPaths(worktreeCwd: String) throws -> [String] {
        let result = try runner.run(
            gitPath,
            args: ["status", "--porcelain", "-z"],
            cwd: worktreeCwd
        )
        try requireSuccess(result, label: "git status --porcelain -z")
        return PorcelainParser.parseStatusPorcelainZ(result.stdout)
    }

    public func unmergedPaths(worktreeCwd: String) throws -> [String] {
        let result = try runner.run(
            gitPath,
            args: ["diff", "--name-only", "--diff-filter=U", "-z"],
            cwd: worktreeCwd
        )
        try requireSuccess(result, label: "git diff --name-only --diff-filter=U -z")
        return result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public func merge(repoCwd: String, branch: String, mode: GitMergeMode, message: String) throws {
        switch mode {
        case .noFF:
            let result = try runner.run(
                gitPath,
                args: ["merge", "--no-ff", "-m", message, branch],
                cwd: repoCwd
            )
            try requireSuccess(result, label: "git merge --no-ff -m '<msg>' \(branch)")
        case .ffOnly:
            let result = try runner.run(
                gitPath,
                args: ["merge", "--ff-only", branch],
                cwd: repoCwd
            )
            try requireSuccess(result, label: "git merge --ff-only \(branch)")
        case .squash:
            let mergeResult = try runner.run(
                gitPath,
                args: ["merge", "--squash", branch],
                cwd: repoCwd
            )
            try requireSuccess(mergeResult, label: "git merge --squash \(branch)")
            let commitResult = try runner.run(
                gitPath,
                args: ["commit", "-m", message],
                cwd: repoCwd
            )
            try requireSuccess(commitResult, label: "git commit -m '<msg>'")
        }
    }

    public func fetch(repoCwd: String, remote: String, branch: String) throws {
        let result = try runner.run(
            gitPath,
            args: ["fetch", remote, branch],
            cwd: repoCwd
        )
        try requireSuccess(result, label: "git fetch \(remote) \(branch)")
    }

    public func rebase(worktreeCwd: String, onto: String) throws {
        let result = try runner.run(
            gitPath,
            args: ["rebase", onto],
            cwd: worktreeCwd
        )
        try requireSuccess(result, label: "git rebase \(onto)")
    }

    public func upstreamRemote(repoCwd: String, branch: String) throws -> String? {
        let result = try runner.run(
            gitPath,
            args: ["config", "--get", "branch.\(branch).remote"],
            cwd: repoCwd
        )
        // git config --get returns 0 when the key is set, 1 when unset.
        switch result.exitCode {
        case 0:
            let name = result.stdoutTrimmed
            return name.isEmpty ? nil : name
        case 1:
            return nil
        default:
            throw VibeChardError.externalCommandFailed(
                cmd: "git config --get branch.\(branch).remote",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    public func revParse(repoCwd: String, ref: String) throws -> String {
        let result = try runner.run(
            gitPath,
            args: ["rev-parse", ref],
            cwd: repoCwd
        )
        try requireSuccess(result, label: "git rev-parse \(ref)")
        return result.stdoutTrimmed
    }

    public func push(repoCwd: String, remote: String, branch: String) throws {
        let result = try runner.run(
            gitPath,
            args: ["push", remote, branch],
            cwd: repoCwd
        )
        try requireSuccess(result, label: "git push \(remote) \(branch)")
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

    /// Parser for `git status --porcelain -z`. Returns every repo-
    /// relative path mentioned by the output (both halves of a rename,
    /// untracked entries, modified entries). Public so unit tests can
    /// exercise the parser without spawning git. (#7)
    ///
    /// `-z` format reference (`man git-status`):
    /// each entry is `XY SP <path>\0`; for renames/copies (`XY` starts
    /// with `R` or `C`), the entry's path is followed by a second
    /// NUL-terminated token containing the original name.
    public static func parseStatusPorcelainZ(_ output: String) -> [String] {
        var paths: [String] = []
        let tokens = output
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
        var i = 0
        while i < tokens.count {
            let raw = tokens[i]
            if raw.isEmpty { i += 1; continue }
            // Must be at least "XY <path>" (3 chars: "XY " + 1).
            guard raw.count >= 4 else { i += 1; continue }
            let xy = String(raw.prefix(2))
            let path = String(raw.dropFirst(3))
            if !path.isEmpty { paths.append(path) }
            let isRename = xy.contains("R") || xy.contains("C")
            if isRename, i + 1 < tokens.count {
                let oldPath = tokens[i + 1]
                if !oldPath.isEmpty { paths.append(oldPath) }
                i += 2
            } else {
                i += 1
            }
        }
        return paths
    }
}
