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

    func fileExists(at path: String) -> Bool {
        files[path] != nil
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
        directories.remove(path)
        // Remove all paths that begin with `path + "/"` too.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for key in files.keys where key.hasPrefix(prefix) { files.removeValue(forKey: key) }
        directories = directories.filter { !$0.hasPrefix(prefix) }
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
}
