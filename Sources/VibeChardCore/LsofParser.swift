import Foundation

/// One process found holding a file inside a worktree path. Surfaced
/// to the user by `vch remove` (#10) so they can close the offending
/// editor / shell before retrying.
public struct WorktreeHolder: Equatable, Sendable {
    public let pid: Int32
    public let command: String
    /// Sample path — the first held file inside the worktree we saw
    /// for this pid. We don't list every held path; agents and humans
    /// only need a hint.
    public let samplePath: String

    public init(pid: Int32, command: String, samplePath: String) {
        self.pid = pid
        self.command = command
        self.samplePath = samplePath
    }
}

/// Parser for `lsof -F pcn` field-mode output. Pulled out so the
/// translation from raw lines → holders is unit-testable without
/// shelling out.
///
/// `lsof -F pcn` produces field records. A typical group looks like:
///
///     p1234              ← process id
///     cVS Code           ← command
///     fcwd               ← (optional) file descriptor type
///     n/path/to/file     ← path
///     n/path/to/another  ← additional path under the same pid
///     p5678
///     ...
///
/// We deduplicate by pid (first matching path wins) so a single editor
/// holding many files inside the worktree is reported once.
public enum LsofParser {

    /// Parse field-mode output and return the subset of holders whose
    /// `n` line is inside `worktreePath`. `selfPID` is filtered so vch
    /// itself never appears in the list (it's about to fork lsof
    /// inside the worktree's own ancestry on some setups).
    public static func parse(
        fieldOutput: String,
        worktreePath: String,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [WorktreeHolder] {
        // Normalize to a trailing slash so a worktree literally named
        // `Foo` doesn't accidentally match an unrelated `Foo-bar`
        // sibling. Empty input → no holders.
        guard !worktreePath.isEmpty else { return [] }
        let prefix = worktreePath.hasSuffix("/") ? worktreePath : worktreePath + "/"

        var pid: Int32?
        var command: String?
        // Insertion-ordered dedupe by pid.
        var seen: [Int32: WorktreeHolder] = [:]
        var order: [Int32] = []

        for raw in fieldOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !raw.isEmpty else { continue }
            let kind = raw.first!
            let value = String(raw.dropFirst())
            switch kind {
            case "p":
                pid = Int32(value)
                command = nil
            case "c":
                command = value
            case "n":
                // A `n` line without a preceding `p` is malformed; ignore.
                guard let currentPID = pid, currentPID != selfPID else { continue }
                if seen[currentPID] != nil { continue }
                if value == worktreePath || value.hasPrefix(prefix) {
                    seen[currentPID] = WorktreeHolder(
                        pid: currentPID,
                        command: command ?? "(unknown)",
                        samplePath: value
                    )
                    order.append(currentPID)
                }
            default:
                continue
            }
        }
        return order.compactMap { seen[$0] }
    }
}

/// Shell-out facade for `lsof +D`. Pulled behind a protocol so
/// `vch remove` tests can fake the holder list.
public protocol WorktreeHolderScanner: Sendable {
    func findHolders(of worktreePath: String) throws -> [WorktreeHolder]
}

/// Production implementation. Runs `/usr/sbin/lsof -F pcn +D <path>`,
/// which scans the directory tree once. Failures (lsof not installed,
/// permission denied on some files inside the tree) downgrade to "no
/// holders" so `vch remove` is never gated on a flaky lsof.
public struct DiskWorktreeHolderScanner: WorktreeHolderScanner {
    public let runner: ProcessRunner
    public let lsofPath: String

    public init(
        runner: ProcessRunner = DiskProcessRunner(),
        lsofPath: String = "/usr/sbin/lsof"
    ) {
        self.runner = runner
        self.lsofPath = lsofPath
    }

    public func findHolders(of worktreePath: String) throws -> [WorktreeHolder] {
        // `+D` recursively walks the tree. lsof exits with 1 when no
        // matches are found, which is the common case — treat it as
        // "no holders" rather than an error.
        let result: ProcessResult
        do {
            result = try runner.run(
                lsofPath,
                args: ["-F", "pcn", "+D", worktreePath],
                cwd: nil,
                env: nil
            )
        } catch {
            // lsof missing or unspawnable → don't block removal. vch
            // remove's job is to remove; this check is best-effort.
            return []
        }
        // Exit codes: 0 = found holders, 1 = no matches, others =
        // unexpected (we still try to parse stdout in case some
        // matches arrived before the error).
        return LsofParser.parse(fieldOutput: result.stdout, worktreePath: worktreePath)
    }
}
