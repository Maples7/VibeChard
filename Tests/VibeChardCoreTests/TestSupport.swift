import Foundation
@testable import VibeChardCore

// Test doubles for `TaskService`. Kept in one place so individual test
// files stay focused on behavior rather than scaffolding.

final class FixedClock: Clock, @unchecked Sendable {
    var current: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = date
    }
    func now() -> Date { current }
}

final class InMemoryFileSystem: FileSystem, @unchecked Sendable {
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private var symlinks: [String: String] = [:]

    func fileExists(at path: String) -> Bool {
        files[path] != nil || symlinks[path] != nil
    }

    func directoryExists(at path: String) -> Bool {
        directories.contains(path)
    }

    func createDirectory(at path: String) throws {
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Re-build all parent paths.
        var prefix = ""
        for c in components.dropFirst() {
            prefix += "/" + c
            directories.insert(prefix)
        }
        // Single-segment relative path edge case (unlikely in tests).
        if !path.hasPrefix("/") {
            components.removeFirst(0)
            directories.insert(path)
        }
    }

    func readFile(at path: String) throws -> Data {
        guard let data = files[path] else {
            throw NSError(domain: "InMemoryFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such file: \(path)"])
        }
        return data
    }

    func writeFileAtomic(_ data: Data, to path: String) throws {
        // Auto-create parents.
        let parent = (path as NSString).deletingLastPathComponent
        try createDirectory(at: parent)
        files[path] = data
    }

    func removeItem(at path: String) throws {
        files.removeValue(forKey: path)
        symlinks.removeValue(forKey: path)
        directories.remove(path)
        // Remove all paths that begin with `path + "/"` too.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for key in files.keys where key.hasPrefix(prefix) { files.removeValue(forKey: key) }
        for key in symlinks.keys where key.hasPrefix(prefix) { symlinks.removeValue(forKey: key) }
        directories = directories.filter { !$0.hasPrefix(prefix) }
    }

    func symlinkDestination(at path: String) -> String? {
        symlinks[path]
    }

    func createSymbolicLink(at linkPath: String, withDestination destination: String) throws {
        if let existing = symlinks[linkPath] {
            if existing == destination { return }
            symlinks[linkPath] = destination
            return
        }
        if files[linkPath] != nil || directories.contains(linkPath) {
            throw VibeChardError.externalCommandFailed(
                cmd: "createSymbolicLink",
                exitCode: 17,
                stderr: "non-symlink already exists at \(linkPath)"
            )
        }
        // Auto-create parent.
        let parent = (linkPath as NSString).deletingLastPathComponent
        try createDirectory(at: parent)
        symlinks[linkPath] = destination
    }

    func copyItem(from source: String, to destination: String) throws {
        if files[destination] != nil || directories.contains(destination) || symlinks[destination] != nil {
            throw VibeChardError.externalCommandFailed(
                cmd: "copyItem",
                exitCode: 17,
                stderr: "destination already exists at \(destination)"
            )
        }
        if let target = symlinks[source] {
            symlinks[destination] = target
            return
        }
        guard let data = files[source] else {
            throw NSError(domain: "InMemoryFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "no such file: \(source)"])
        }
        files[destination] = data
    }

    // Test helpers
    func seedDirectory(_ path: String) { directories.insert(path) }
    func seedFile(_ path: String, data: Data) {
        let parent = (path as NSString).deletingLastPathComponent
        try? createDirectory(at: parent)
        files[path] = data
    }
    var fileKeys: [String] { Array(files.keys).sorted() }
    var directoryKeys: [String] { Array(directories).sorted() }
    var symlinkKeys: [String] { Array(symlinks.keys).sorted() }
    func symlink(at path: String) -> String? { symlinks[path] }
}

/// In-memory `GitClient` whose semantics roughly mirror real git for the
/// behaviors `TaskService` exercises.
final class FakeGitClient: GitClient, @unchecked Sendable {
    var entries: [WorktreeEntry] = []
    var branches: Set<String> = []
    var unmergedBranches: Set<String> = []
    var dirtyWorktrees: Set<String> = []
    var headShortSHA: String = "1234abc"

    var pruneCalls = 0
    var addNewBranchCalls: [(path: String, branch: String, base: String)] = []
    var addExistingCalls: [(path: String, branch: String)] = []
    var removeCalls: [(path: String, force: Bool)] = []
    var branchDeleteCalls: [String] = []
    var branchDeleteForceCalls: [String] = []
    var appendExcludesCalls: [(worktreeCwd: String, patterns: [String])] = []
    var listUntrackedCalls: [String] = []
    /// Per-cwd untracked file list returned by `listUntrackedFiles`.
    var untrackedFilesByCwd: [String: [String]] = [:]

    func worktreeList(repoCwd: String) throws -> [WorktreeEntry] { entries }

    func worktreeAddNewBranch(repoCwd: String, path: String, branch: String, base: String) throws {
        if branches.contains(branch) {
            throw VibeChardError.externalCommandFailed(cmd: "git worktree add -b \(branch)", exitCode: 128, stderr: "branch exists")
        }
        addNewBranchCalls.append((path, branch, base))
        branches.insert(branch)
        entries.append(WorktreeEntry(path: path, branch: branch))
    }

    func worktreeAddExisting(repoCwd: String, path: String, branch: String) throws {
        addExistingCalls.append((path, branch))
        entries.append(WorktreeEntry(path: path, branch: branch))
    }

    func worktreeRemove(repoCwd: String, path: String, force: Bool) throws {
        removeCalls.append((path, force))
        entries.removeAll { $0.path == path }
    }

    func worktreePrune(repoCwd: String) throws {
        pruneCalls += 1
    }

    func branchExists(repoCwd: String, name: String) throws -> Bool {
        branches.contains(name)
    }

    func branchDelete(repoCwd: String, name: String) throws {
        branchDeleteCalls.append(name)
        if unmergedBranches.contains(name) {
            throw VibeChardError.unmergedBranch(name: name)
        }
        branches.remove(name)
    }

    func branchDeleteForce(repoCwd: String, name: String) throws {
        branchDeleteForceCalls.append(name)
        branches.remove(name)
        unmergedBranches.remove(name)
    }

    func statusIsDirty(worktreeCwd: String) throws -> Bool {
        dirtyWorktrees.contains(worktreeCwd)
    }

    func revParseHEADShort(repoCwd: String) throws -> String {
        headShortSHA
    }

    func appendLocalExcludes(worktreeCwd: String, patterns: [String]) throws {
        appendExcludesCalls.append((worktreeCwd, patterns))
    }

    func listUntrackedFiles(worktreeCwd: String) throws -> [String] {
        listUntrackedCalls.append(worktreeCwd)
        return untrackedFilesByCwd[worktreeCwd] ?? []
    }

    // MARK: - Land (#7) protocol surface

    /// Branch that `currentBranch` should return for a given cwd.
    /// Defaults to nil (detached HEAD).
    var currentBranchByCwd: [String: String?] = [:]
    /// Diff outputs keyed by `"\(base)..\(head)"`.
    var diffNamesByRange: [String: [String]] = [:]
    /// Ahead counts keyed by `"\(base)..\(head)"`.
    var revListCountByRange: [String: Int] = [:]
    /// Subjects keyed by branch.
    var lastSubjectByBranch: [String: String] = [:]
    /// Paths returned by `statusPaths` keyed by worktree cwd.
    var statusPathsByCwd: [String: [String]] = [:]
    /// Recorded `merge` calls.
    var mergeCalls: [(repoCwd: String, branch: String, mode: GitMergeMode, message: String)] = []
    /// If non-nil, `merge` will throw this error.
    var mergeError: VibeChardError?

    func currentBranch(repoCwd: String) throws -> String? {
        if let entry = currentBranchByCwd[repoCwd] {
            return entry
        }
        return nil
    }

    func diffNamesOnly(repoCwd: String, base: String, head: String) throws -> [String] {
        diffNamesByRange["\(base)..\(head)"] ?? []
    }

    func revListCount(repoCwd: String, base: String, head: String) throws -> Int {
        revListCountByRange["\(base)..\(head)"] ?? 0
    }

    func lastNonMergeSubject(repoCwd: String, branch: String) throws -> String? {
        lastSubjectByBranch[branch]
    }

    func statusPaths(worktreeCwd: String) throws -> [String] {
        statusPathsByCwd[worktreeCwd] ?? []
    }

    func merge(repoCwd: String, branch: String, mode: GitMergeMode, message: String) throws {
        if let error = mergeError {
            throw error
        }
        mergeCalls.append((repoCwd, branch, mode, message))
    }

    // MARK: - Sync (#25) protocol surface

    /// Recorded `fetch` calls.
    var fetchCalls: [(repoCwd: String, remote: String, branch: String)] = []
    /// If non-nil, `fetch` throws this error.
    var fetchError: VibeChardError?
    /// Recorded `rebase` calls.
    var rebaseCalls: [(worktreeCwd: String, onto: String)] = []
    /// If non-nil, `rebase` throws this error.
    var rebaseError: VibeChardError?
    /// Configured upstream remote per `branch`. Default = nil (unset).
    var upstreamRemoteByBranch: [String: String] = [:]
    /// Configured rev-parse mappings; ref → resolved SHA.
    var revParseByRef: [String: String] = [:]
    /// If a ref isn't in `revParseByRef`, default to this synthetic SHA
    /// derived from the ref name. Tests that need exact control should
    /// preload `revParseByRef`.
    var revParseFallback: ((String) -> String)? = nil

    func fetch(repoCwd: String, remote: String, branch: String) throws {
        if let error = fetchError {
            throw error
        }
        fetchCalls.append((repoCwd, remote, branch))
    }

    func rebase(worktreeCwd: String, onto: String) throws {
        if let error = rebaseError {
            throw error
        }
        rebaseCalls.append((worktreeCwd, onto))
    }

    func upstreamRemote(repoCwd: String, branch: String) throws -> String? {
        upstreamRemoteByBranch[branch]
    }

    func revParse(repoCwd: String, ref: String) throws -> String {
        if let sha = revParseByRef[ref] { return sha }
        if let fallback = revParseFallback { return fallback(ref) }
        // Default: synthesise a deterministic 40-char SHA from the ref so
        // tests that don't care about the exact value still get a stable,
        // distinguishable answer.
        return String(repeating: "a", count: 40 - ref.count) + ref
    }

    // MARK: - Land --push (#49) protocol surface

    /// Recorded `push` calls.
    var pushCalls: [(repoCwd: String, remote: String, branch: String)] = []
    /// If non-nil, `push` throws this error.
    var pushError: VibeChardError?

    func push(repoCwd: String, remote: String, branch: String) throws {
        if let error = pushError {
            throw error
        }
        pushCalls.append((repoCwd, remote, branch))
    }
}
